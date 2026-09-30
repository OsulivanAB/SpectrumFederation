-- Early Preparation Whispers.
-- The current Loot Helper session coordinator maintains equipment observations for
-- profile members in the raid and sends the existing Pre-Raid missing-requirements
-- whisper once Spectrum has a complete, current observation that the shared Raid
-- Equipment policy classifies as Unprepared.
--
-- Combat does not turn this feature off. The shared inspect pipeline still pauses
-- NotifyInspect during combat and while the Blizzard Inspect window is open.
-- A whisper is sent only from a fresh complete observation, including one captured
-- before combat. Incomplete or stale data is never treated as Unprepared.
--
-- Warning dedupe is runtime session state. It is synchronized to other admins and
-- stored on the session record so a reload or coordinator change does not send a
-- second missing-requirements whisper. It is not profile history.
--
-- luacheck: globals SpectrumFederationDB

local _, SF = ...

SF.RaidEquipment = SF.RaidEquipment or {}

local EarlyPrep = {
	SETTING_PATH = "lootHelper.earlyPreparationWhispers",
	CONSUMER_REASON = "early_preparation",
	MAX_NOTICE_MEMBERS = 80,
	-- One slot per comms sender. A sender name comes from the client, so one
	-- character cannot fill the map by forging other names.
	MAX_DEFERRED_SENDERS = 40,
	-- Non-coordinator admins retry PREP_NOTICE until a coordinator heartbeat
	-- covers their local warned / raid-check state. The first burst is every
	-- heartbeat; later attempts back off to limit chat spam without giving up.
	MAX_OUTBOUND_BURST = 12,
	OUTBOUND_BACKOFF_HEARTBEATS = 4,
	-- Coordinator-serialized exclusive claims before a missing-requirements whisper.
	-- Claims are session-scoped, coordinator-epoch-aware, and expire if unused.
	CLAIM_TTL_SECONDS = 20,
	MAX_CLAIMS = 40,
	MAX_PENDING_WHISPERS = 40,
}
SF.RaidEquipment.EarlyPreparation = EarlyPrep

local function DebugInfo(message, ...)
	if SF.Debug then
		SF.Debug:Info("EARLY_PREP", message, ...)
	end
end

local function DebugVerbose(message, ...)
	if SF.Debug then
		SF.Debug:Verbose("EARLY_PREP", message, ...)
	end
end

function EarlyPrep.IsSettingEnabled(value)
	if value == nil then
		return true
	end
	return value and true or false
end

function EarlyPrep.ValidMemberId(id)
	if type(id) ~= "string" then
		return false
	end
	if #id < 3 or #id > 80 then
		return false
	end
	if string.find(id, "%c") then
		return false
	end
	return true
end

function EarlyPrep.SameMember(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "string" or type(b) ~= "string" then
		return false
	end
	local nameUtil = SF.NameUtil
	if nameUtil and nameUtil.SamePlayer then
		return nameUtil.SamePlayer(a, b) and true or false
	end
	return false
end

function EarlyPrep.NewNotice()
	return {
		sessionId = nil,
		profileId = nil,
		warned = {},
		raidCheckBegun = false,
	}
end

EarlyPrep.notice = EarlyPrep.NewNotice()

function EarlyPrep.BindNotice(notice, sessionId, profileId)
	if type(notice) ~= "table" then
		return false
	end
	if notice.sessionId == sessionId and notice.profileId == profileId then
		return false
	end
	notice.sessionId = sessionId
	notice.profileId = profileId
	notice.warned = {}
	notice.raidCheckBegun = false
	return true
end

function EarlyPrep.IsWarned(notice, memberId)
	if type(notice) ~= "table" or type(notice.warned) ~= "table" or not EarlyPrep.ValidMemberId(memberId) then
		return false
	end
	if notice.warned[memberId] then
		return true
	end
	for id in pairs(notice.warned) do
		if EarlyPrep.SameMember(id, memberId) then
			return true
		end
	end
	return false
end

function EarlyPrep.WarningRecordable(notice, memberId)
	if type(notice) ~= "table" or not EarlyPrep.ValidMemberId(memberId) then
		return false
	end
	if EarlyPrep.IsWarned(notice, memberId) then
		return false
	end
	local count = 0
	if type(notice.warned) == "table" then
		for _ in pairs(notice.warned) do
			count = count + 1
		end
	end
	return count < EarlyPrep.MAX_NOTICE_MEMBERS
end

function EarlyPrep.MarkWarned(notice, memberId)
	if not EarlyPrep.WarningRecordable(notice, memberId) then
		return false
	end
	notice.warned = notice.warned or {}
	notice.warned[memberId] = true
	return true
end

-- Pure coordinator claim decision for tests and grant handling.
-- ctx: alreadyWarned, claimActive, claimerIsSender, epochMatch, atCap
function EarlyPrep.ClaimGrantDecision(ctx)
	ctx = type(ctx) == "table" and ctx or {}
	if ctx.alreadyWarned == true then
		return "deny", "warned"
	end
	if ctx.epochMatch == false then
		return "deny", "epoch"
	end
	if ctx.claimActive == true and ctx.claimerIsSender ~= true then
		return "deny", "held"
	end
	if ctx.claimActive ~= true and ctx.atCap == true then
		return "deny", "cap"
	end
	return "grant", ctx.claimActive == true and "refresh" or "new"
end

function EarlyPrep.WarnedArray(notice)
	local warned = {}
	if type(notice) ~= "table" or type(notice.warned) ~= "table" then
		return warned
	end
	for id in pairs(notice.warned) do
		if EarlyPrep.ValidMemberId(id) then
			warned[#warned + 1] = id
		end
	end
	table.sort(warned)
	return warned
end

-- Duplicate and out-of-order notices are monotonic. A false raidCheckBegun never
-- clears a true one, and a snapshot never removes someone already warned.
function EarlyPrep.ApplyNotice(notice, sessionId, profileId, payload)
	if type(notice) ~= "table" or type(payload) ~= "table" then
		return false, false
	end
	if type(sessionId) ~= "string" or sessionId == "" or type(profileId) ~= "string" or profileId == "" then
		return false, false
	end
	if notice.sessionId ~= sessionId or notice.profileId ~= profileId then
		return false, false
	end
	if payload.sessionId ~= sessionId or payload.profileId ~= profileId then
		return false, false
	end

	local changed = false
	if EarlyPrep.MarkWarned(notice, payload.memberId) then
		changed = true
	end
	if type(payload.warned) == "table" then
		local seen = 0
		for _, id in ipairs(payload.warned) do
			seen = seen + 1
			if seen > EarlyPrep.MAX_NOTICE_MEMBERS then
				break
			end
			if EarlyPrep.MarkWarned(notice, id) then
				changed = true
			end
		end
	end
	if payload.raidCheckBegun == true and notice.raidCheckBegun ~= true then
		notice.raidCheckBegun = true
		changed = true
	end
	return true, changed
end

function EarlyPrep.WindowOpen(ctx)
	ctx = type(ctx) == "table" and ctx or {}
	if ctx.settingEnabled ~= true then
		return false, "setting"
	end
	if ctx.sessionActive ~= true then
		return false, "session"
	end
	if ctx.announced ~= true then
		return false, "announced"
	end
	if ctx.isCoordinator ~= true then
		return false, "coordinator"
	end
	if ctx.isEffectiveAdmin ~= true then
		return false, "admin"
	end
	if ctx.profileReady ~= true then
		return false, "profile"
	end
	if ctx.groupIsRaid ~= true then
		return false, "party"
	end
	if ctx.raidCheckBegun == true then
		return false, "raid_check"
	end
	return true, "open"
end

function EarlyPrep.ObservationShouldWarn(ctx)
	ctx = type(ctx) == "table" and ctx or {}
	if ctx.eligible ~= true then
		return false, "ineligible"
	end
	if ctx.inRaid ~= true then
		return false, "left"
	end
	if ctx.fresh ~= true then
		return false, "stale"
	end
	if ctx.complete ~= true then
		return false, "incomplete"
	end
	if ctx.prepared == true then
		return false, "prepared"
	end
	if ctx.alreadyWarned == true then
		return false, "warned"
	end
	return true, "send"
end

function EarlyPrep.ShouldWarn(ctx)
	local open, why = EarlyPrep.WindowOpen(ctx)
	if not open then
		return false, why
	end
	return EarlyPrep.ObservationShouldWarn(ctx)
end

function EarlyPrep.ShouldNoteRaidCheckBegun(mode, opts)
	if mode ~= "raid" then
		return false
	end
	if type(opts) ~= "table" or opts.sessionMismatch == true then
		return false
	end
	if type(opts.expectedSessionId) ~= "string" or opts.expectedSessionId == "" then
		return false
	end
	return true
end

-- The coordinator's send-accepted flag is not set on clients that joined
-- through SES_START or SES_REANNOUNCE. Their active session descriptor is
-- still the session that shares missing-whisper dedupe. A coordinator who has
-- not successfully announced yet does not.
function EarlyPrep.SessionAnnouncedForDedupe(sessionActive, sendAccepted, isCoordinator, sessionId)
	if sessionActive ~= true then
		return false
	end
	if type(sessionId) ~= "string" or sessionId == "" then
		return false
	end
	if sendAccepted == true then
		return true
	end
	return isCoordinator ~= true
end

function EarlyPrep.SessionDedupeApplies(run, session)
	if type(run) ~= "table" or type(session) ~= "table" then
		return false
	end
	if session.active ~= true or session.announced ~= true then
		return false
	end
	if run.sessionMismatch == true then
		return false
	end
	if type(session.sessionId) ~= "string" or session.sessionId == "" then
		return false
	end
	if run.expectedSessionId ~= session.sessionId then
		return false
	end
	if type(run.expectedSessionProfileId) == "string" and type(session.profileId) == "string" then
		if run.expectedSessionProfileId ~= session.profileId then
			return false
		end
	end
	return true
end

-- Session dedupe replaces the calendar-day fallback only while a matching
-- announced session exists. Prepared/point whispers are a different message.
function EarlyPrep.MissingWhisperAction(ctx)
	ctx = type(ctx) == "table" and ctx or {}
	if ctx.whispersEnabled ~= true then
		return "skip"
	end
	if ctx.sessionDedupe == true then
		if ctx.alreadyWarned == true then
			return "session_contacted"
		end
		return "send"
	end
	if ctx.alreadyToday == true then
		return "today"
	end
	return "send"
end

function EarlyPrep.PreparedWhisperSuppressedByMissingWarning()
	return false
end

-- Diagnostic labels such as "equipment page shown" and "equipment page hidden"
-- must not become separate consumers. opts.consumerId is the stable key.
function EarlyPrep.ConsumerId(reason, opts)
	if type(opts) == "table" and type(opts.consumerId) == "string" and opts.consumerId ~= "" then
		return opts.consumerId
	end
	if type(reason) == "string" and reason ~= "" then
		return reason
	end
	return "default"
end

function EarlyPrep.MutateConsumers(consumers, reason, enabled, spec)
	if type(consumers) ~= "table" then
		consumers = {}
	end
	if type(reason) ~= "string" or reason == "" then
		reason = "default"
	end
	if enabled then
		consumers[reason] = spec or {}
	else
		consumers[reason] = nil
	end
	return consumers, next(consumers) ~= nil
end

-- An empty consumer map means the caller already decided inspection is on and
-- did not record a filter, so every grouped unit remains eligible.
function EarlyPrep.ConsumerWantsUnit(consumers, info)
	if type(consumers) ~= "table" or next(consumers) == nil then
		return true
	end
	local unfiltered = false
	local matched = false
	for _, spec in pairs(consumers) do
		local filter = type(spec) == "table" and spec.filter or nil
		if type(filter) ~= "function" then
			unfiltered = true
		elseif filter(info) then
			matched = true
		end
	end
	if unfiltered then
		return true
	end
	return matched
end

function EarlyPrep.EligibleFilter(info)
	local ep = SF.RaidEquipment and SF.RaidEquipment.EarlyPreparation
	if not ep or not ep.IsEligibleTarget then
		return false
	end
	return ep:IsEligibleTarget(info and info.id) and true or false
end

function EarlyPrep:ReadSetting()
	local store = SF.SettingsStore
	if not store or type(store.Get) ~= "function" then
		return nil
	end
	return store:Get(self.SETTING_PATH)
end

function EarlyPrep:GetSessionProfile()
	local sync = SF.LootHelperSync
	if not sync or type(sync.GetSessionProfileId) ~= "function" or type(sync.FindLocalProfileById) ~= "function" then
		return nil, nil
	end
	local profileId = sync:GetSessionProfileId()
	if type(profileId) ~= "string" or profileId == "" then
		return nil, nil
	end
	return sync:FindLocalProfileById(profileId), profileId
end

function EarlyPrep:IsEffectiveAdmin(profile)
	if not profile then
		return false
	end
	local impersonation = SF.LootHelperImpersonation
	if impersonation and type(impersonation.IsEffectiveLocalAdmin) == "function" then
		return impersonation:IsEffectiveLocalAdmin(profile) and true or false
	end
	if type(profile.IsCurrentUserAdmin) == "function" then
		return profile:IsCurrentUserAdmin() and true or false
	end
	return false
end

function EarlyPrep:FindProfileMember(profile, memberId)
	if not profile or not EarlyPrep.ValidMemberId(memberId) then
		return nil
	end
	if type(profile.GetMemberByID) == "function" then
		local member = profile:GetMemberByID(memberId)
		if member then
			return member
		end
	end
	if type(profile.members) == "table" then
		return profile.members[memberId]
	end
	return nil
end

function EarlyPrep:IsProfileMember(profile, memberId)
	return self:FindProfileMember(profile, memberId) ~= nil
end

function EarlyPrep:BeginMembershipPass()
	local depth = self._membershipDepth or 0
	self._membershipDepth = depth + 1
	if depth > 0 then
		return
	end
	local set = self._membershipSet
	if type(set) ~= "table" then
		set = {}
		self._membershipSet = set
	else
		for key in pairs(set) do
			set[key] = nil
		end
	end
	local raidCheck = SF.RaidCheck
	local ids = {}
	if raidCheck and type(raidCheck.CollectGroupMemberIds) == "function" then
		ids = raidCheck:CollectGroupMemberIds() or {}
	end
	for i = 1, #ids do
		local id = ids[i]
		if type(id) == "string" and id ~= "" then
			set[id] = true
		end
	end
	self._membershipPass = true
end

function EarlyPrep:EndMembershipPass()
	local depth = self._membershipDepth or 0
	if depth > 1 then
		self._membershipDepth = depth - 1
		return
	end
	self._membershipDepth = 0
	self._membershipPass = false
	local set = self._membershipSet
	if type(set) == "table" then
		for key in pairs(set) do
			set[key] = nil
		end
	end
end

function EarlyPrep:MemberInCurrentPass(memberId)
	local set = self._membershipSet
	if type(set) ~= "table" then
		return false
	end
	if set[memberId] then
		return true
	end
	if SF.NameUtil and type(SF.NameUtil.SamePlayer) == "function" then
		for id in pairs(set) do
			if SF.NameUtil.SamePlayer(id, memberId) then
				return true
			end
		end
	end
	return false
end

function EarlyPrep:IsEligibleTarget(memberId)
	if not EarlyPrep.ValidMemberId(memberId) then
		return false
	end
	local profile = self:GetSessionProfile()
	if not self:IsProfileMember(profile, memberId) then
		return false
	end
	if self._membershipPass then
		return self:MemberInCurrentPass(memberId)
	end
	local raidCheck = SF.RaidCheck
	if not raidCheck or type(raidCheck.IsGroupMember) ~= "function" then
		return false
	end
	return raidCheck:IsGroupMember(memberId) and true or false
end

function EarlyPrep:SyncNoticeToSession()
	local sync = SF.LootHelperSync
	local sessionId = nil
	local profileId = nil
	if sync and type(sync.IsSessionActive) == "function" and sync:IsSessionActive() then
		if type(sync.GetSessionId) == "function" then
			sessionId = sync:GetSessionId()
		end
		if type(sync.GetSessionProfileId) == "function" then
			profileId = sync:GetSessionProfileId()
		end
	end
	self.notice = self.notice or EarlyPrep.NewNotice()
	if EarlyPrep.BindNotice(self.notice, sessionId, profileId) then
		self._rejectLogged = {}
		self._skipStamp = nil
	end
end

function EarlyPrep:WasWarned(memberId)
	return EarlyPrep.IsWarned(self.notice, memberId)
end

function EarlyPrep:HasShareableNotice()
	local notice = self.notice
	if type(notice) ~= "table" or type(notice.sessionId) ~= "string" or notice.sessionId == "" then
		return false
	end
	if notice.raidCheckBegun == true then
		return true
	end
	return type(notice.warned) == "table" and next(notice.warned) ~= nil
end

function EarlyPrep:ComputeWindow()
	local sync = SF.LootHelperSync
	local sessionActive = sync and type(sync.IsSessionActive) == "function" and sync:IsSessionActive() and true or false
	local announced = false
	local isCoordinator = false
	if sessionActive and type(sync.HasAnnouncedCurrentSession) == "function" then
		announced = sync:HasAnnouncedCurrentSession() and true or false
	end
	if sessionActive and sync.state and sync.state.isCoordinator == true then
		isCoordinator = true
	end
	local profile = self:GetSessionProfile()
	local groupIsRaid = IsInRaid and IsInRaid() and true or false
	local raidCheckBegun = false
	if self.notice and self.notice.sessionId and self.notice.raidCheckBegun == true then
		raidCheckBegun = true
	end
	local open = EarlyPrep.WindowOpen({
		settingEnabled = EarlyPrep.IsSettingEnabled(self:ReadSetting()),
		sessionActive = sessionActive,
		announced = announced,
		isCoordinator = isCoordinator,
		isEffectiveAdmin = self:IsEffectiveAdmin(profile),
		profileReady = profile ~= nil,
		groupIsRaid = groupIsRaid,
		raidCheckBegun = raidCheckBegun,
	})
	return open and true or false
end

function EarlyPrep:UsesSessionDedupe(run, session)
	if not EarlyPrep.SessionDedupeApplies(run, session) then
		return false
	end
	self:SyncNoticeToSession()
	return self.notice and self.notice.sessionId == session.sessionId
end

function EarlyPrep:WritePersisted(persisted)
	if type(persisted) ~= "table" then
		return
	end
	local notice = self.notice
	if type(notice) == "table"
		and notice.sessionId == persisted.sessionId
		and notice.profileId == persisted.profileId
		and self:HasShareableNotice()
	then
		persisted.prepNotice = {
			sessionId = notice.sessionId,
			profileId = notice.profileId,
			raidCheckBegun = notice.raidCheckBegun and true or false,
			warned = EarlyPrep.WarnedArray(notice),
		}
	else
		persisted.prepNotice = nil
	end

	local deferred = self._deferredNotices
	if type(deferred) ~= "table"
		or deferred.sessionId ~= persisted.sessionId
		or deferred.profileId ~= persisted.profileId
		or type(deferred.bySender) ~= "table"
	then
		persisted.deferredPrepNotices = nil
		return
	end
	local bySender = {}
	local count = 0
	for sender, senderNotice in pairs(deferred.bySender) do
		if type(sender) == "string" and sender ~= "" and type(senderNotice) == "table" then
			count = count + 1
			if count > EarlyPrep.MAX_DEFERRED_SENDERS then
				break
			end
			bySender[sender] = {
				raidCheckBegun = senderNotice.raidCheckBegun and true or false,
				warned = EarlyPrep.WarnedArray(senderNotice),
			}
		end
	end
	if next(bySender) == nil then
		persisted.deferredPrepNotices = nil
		return
	end
	persisted.deferredPrepNotices = {
		sessionId = deferred.sessionId,
		profileId = deferred.profileId,
		bySender = bySender,
	}
end

function EarlyPrep:PersistActive()
	local db = (SpectrumFederationDB and SpectrumFederationDB.lootHelper) or SF.lootHelperDB
	if type(db) ~= "table" or type(db.syncSession) ~= "table" then
		return
	end
	self:WritePersisted(db.syncSession)
end

-- A restored shareable notice may never have reached the coordinator. Keep the
-- non-coordinator publish obligation until a covering heartbeat arrives.
function EarlyPrep:RestoreOutboundPending()
	self:ClearOutboundPending()
	if not self:HasShareableNotice() then
		return false
	end
	local sync = SF.LootHelperSync
	if sync and sync.state and sync.state.isCoordinator == true then
		return false
	end
	self:MarkOutboundPending()
	return true
end

function EarlyPrep:InvalidateObservationSkips(reason)
	if self._skipStamp == nil then
		return false
	end
	self._skipStamp = nil
	DebugVerbose("Cleared preparation observation skips (%s)", tostring(reason or "item_data"))
	return true
end

function EarlyPrep:RestorePersisted(persisted)
	if type(persisted) ~= "table" then
		return
	end
	local saved = persisted.prepNotice
	if type(saved) == "table"
		and saved.sessionId == persisted.sessionId
		and saved.profileId == persisted.profileId
	then
		self.notice = EarlyPrep.NewNotice()
		self.notice.sessionId = persisted.sessionId
		self.notice.profileId = persisted.profileId
		EarlyPrep.ApplyNotice(self.notice, persisted.sessionId, persisted.profileId, {
			sessionId = persisted.sessionId,
			profileId = persisted.profileId,
			warned = saved.warned,
			raidCheckBegun = saved.raidCheckBegun == true,
		})
	end

	local savedDeferred = persisted.deferredPrepNotices
	self._deferredNotices = nil
	if type(savedDeferred) == "table"
		and savedDeferred.sessionId == persisted.sessionId
		and savedDeferred.profileId == persisted.profileId
		and type(savedDeferred.bySender) == "table"
	then
		local restored = {
			sessionId = persisted.sessionId,
			profileId = persisted.profileId,
			bySender = {},
		}
		local count = 0
		for sender, snap in pairs(savedDeferred.bySender) do
			if type(sender) == "string" and sender ~= "" and type(snap) == "table" then
				count = count + 1
				if count > EarlyPrep.MAX_DEFERRED_SENDERS then
					break
				end
				local notice = EarlyPrep.NewNotice()
				notice.sessionId = persisted.sessionId
				notice.profileId = persisted.profileId
				EarlyPrep.ApplyNotice(notice, persisted.sessionId, persisted.profileId, {
					sessionId = persisted.sessionId,
					profileId = persisted.profileId,
					warned = snap.warned,
					raidCheckBegun = snap.raidCheckBegun == true,
				})
				restored.bySender[sender] = notice
			end
		end
		if next(restored.bySender) ~= nil then
			self._deferredNotices = restored
		end
	end

	self:RestoreOutboundPending()
end

function EarlyPrep:OnSessionReset(reason)
	DebugVerbose("Cleared early preparation session state (%s)", tostring(reason))
	self.notice = EarlyPrep.NewNotice()
	self._windowOpen = false
	self._wasCoordinator = false
	self._rejectLogged = {}
	self._deferredNotices = nil
	self._outboundPending = false
	self._outboundAttempts = 0
	self._outboundHeartbeatSkip = 0
	self._skipStamp = nil
	self._evaluating = false
	self._refreshing = false
	self._claims = nil
	self._pendingWhispers = nil
	self._claimSeq = 0
	local raidCheck = SF.RaidCheck
	if raidCheck and type(raidCheck.SetBackgroundInspectEnabled) == "function" then
		raidCheck:SetBackgroundInspectEnabled(false, self.CONSUMER_REASON)
	end
end

function EarlyPrep:NoteReject(sender, reason)
	self._rejectLogged = self._rejectLogged or {}
	local key = tostring(sender or "?") .. ":" .. tostring(reason or "?")
	if self._rejectLogged[key] then
		return
	end
	local count = 0
	for _ in pairs(self._rejectLogged) do
		count = count + 1
	end
	if count >= 20 then
		return
	end
	self._rejectLogged[key] = true
	DebugVerbose("Ignored preparation notice from %s (%s)", tostring(sender), tostring(reason))
end

function EarlyPrep:AttachToPayload(payload)
	if type(payload) ~= "table" then
		return payload
	end
	local prepNotice = self:HeartbeatPayload()
	if type(prepNotice) == "table" then
		payload.prepNotice = prepNotice
	end
	return payload
end

function EarlyPrep:HeartbeatPayload()
	local sync = SF.LootHelperSync
	if not sync or not sync.state or sync.state.sessionId ~= (self.notice and self.notice.sessionId) then
		return nil
	end
	if not self:HasShareableNotice() then
		return nil
	end
	return {
		raidCheckBegun = self.notice.raidCheckBegun and true or false,
		warned = EarlyPrep.WarnedArray(self.notice),
	}
end

-- A missing local profile is not the same as a known unauthorized sender.
-- "defer" keeps the snapshot until that profile can prove the sender.
function EarlyPrep.PrepNoticeSenderState(profilePresent, authorized)
	if profilePresent ~= true then
		return "defer"
	end
	if authorized == true then
		return "apply"
	end
	return "reject"
end

-- A cache entry that reused an older slot or item level is not a fresh observation.
function EarlyPrep.ObservationAuthoritative(entry)
	if type(entry) ~= "table" then
		return false
	end
	return entry.blended ~= true
end

-- True when the remote payload already contains every local warned id and the
-- raid-check-begun flag. Used so a non-coordinator can stop retrying PREP_NOTICE.
function EarlyPrep.RemoteCoversLocal(localNotice, remotePayload)
	if type(localNotice) ~= "table" or type(remotePayload) ~= "table" then
		return false
	end
	local sessionId = localNotice.sessionId
	local profileId = localNotice.profileId
	if type(sessionId) ~= "string" or sessionId == "" or type(profileId) ~= "string" or profileId == "" then
		return false
	end
	if localNotice.raidCheckBegun == true and remotePayload.raidCheckBegun ~= true then
		return false
	end
	local cover = EarlyPrep.NewNotice()
	cover.sessionId = sessionId
	cover.profileId = profileId
	EarlyPrep.ApplyNotice(cover, sessionId, profileId, {
		sessionId = sessionId,
		profileId = profileId,
		memberId = remotePayload.memberId,
		warned = remotePayload.warned,
		raidCheckBegun = remotePayload.raidCheckBegun == true,
	})
	if type(localNotice.warned) ~= "table" then
		return true
	end
	for id in pairs(localNotice.warned) do
		if not EarlyPrep.IsWarned(cover, id) then
			return false
		end
	end
	return true
end

function EarlyPrep:SenderInGroup(sender)
	local sync = SF.LootHelperSync
	if not sync or type(sync.IsRequesterInGroup) ~= "function" then
		return false
	end
	return sync:IsRequesterInGroup(sender) == true
end

function EarlyPrep:ClearOutboundPending()
	self._outboundPending = false
	self._outboundAttempts = 0
	self._outboundHeartbeatSkip = 0
end

function EarlyPrep:MarkOutboundPending()
	self._outboundPending = true
	self._outboundAttempts = 0
	self._outboundHeartbeatSkip = 0
end

function EarlyPrep:SenderIsCoordinator(sender)
	local sync = SF.LootHelperSync
	if not sync or not sync.state or type(sender) ~= "string" or sender == "" then
		return false
	end
	local coordinator = sync.state.coordinator
	if type(coordinator) ~= "string" or coordinator == "" then
		return false
	end
	return EarlyPrep.SameMember(sender, coordinator)
end

-- Only coordinator-authored coverage clears the publish obligation. A peer
-- admin snapshot can match local state without the coordinator having it.
function EarlyPrep:ObserveRemoteCoverage(prepNotice, sender)
	if not self._outboundPending then
		return
	end
	if not self:HasShareableNotice() then
		self:ClearOutboundPending()
		return
	end
	if not self:SenderIsCoordinator(sender) then
		return
	end
	if EarlyPrep.RemoteCoversLocal(self.notice, prepNotice) then
		self:ClearOutboundPending()
	end
end

function EarlyPrep:RetryOutboundNotice(reason)
	if not self._outboundPending or not self:HasShareableNotice() then
		return false
	end
	local sync = SF.LootHelperSync
	if sync and sync.state and sync.state.isCoordinator == true then
		-- Coordinator heartbeats already carry the shareable snapshot.
		self:ClearOutboundPending()
		return false
	end
	local attempts = tonumber(self._outboundAttempts) or 0
	local interval = 1
	if attempts >= EarlyPrep.MAX_OUTBOUND_BURST then
		interval = EarlyPrep.OUTBOUND_BACKOFF_HEARTBEATS
	end
	local skip = tonumber(self._outboundHeartbeatSkip) or 0
	skip = skip + 1
	if skip < interval then
		self._outboundHeartbeatSkip = skip
		return false
	end
	self._outboundHeartbeatSkip = 0
	self._outboundAttempts = attempts + 1
	DebugVerbose("Retrying preparation notice publish (%s, attempt=%s)", tostring(reason or "retry"), tostring(self._outboundAttempts))
	return self:BroadcastNotice("snapshot")
end

function EarlyPrep:DeferPrepNotice(sessionId, profileId, sender, prepNotice)
	if type(prepNotice) ~= "table" or type(sessionId) ~= "string" or sessionId == "" then
		return false
	end
	if type(profileId) ~= "string" or profileId == "" then
		return false
	end
	-- Authorization happens later, so a notice with no sender can never be applied.
	if type(sender) ~= "string" or sender == "" then
		return false
	end
	local deferred = self._deferredNotices
	if type(deferred) ~= "table" or deferred.sessionId ~= sessionId or deferred.profileId ~= profileId then
		deferred = {
			sessionId = sessionId,
			profileId = profileId,
			bySender = {},
		}
		self._deferredNotices = deferred
	end
	local notice = deferred.bySender[sender]
	if type(notice) ~= "table" then
		local count = 0
		for _ in pairs(deferred.bySender) do
			count = count + 1
		end
		if count >= EarlyPrep.MAX_DEFERRED_SENDERS then
			return false
		end
		notice = EarlyPrep.NewNotice()
		notice.sessionId = sessionId
		notice.profileId = profileId
		deferred.bySender[sender] = notice
	end
	EarlyPrep.ApplyNotice(notice, sessionId, profileId, {
		sessionId = sessionId,
		profileId = profileId,
		memberId = prepNotice.memberId,
		warned = prepNotice.warned,
		raidCheckBegun = prepNotice.raidCheckBegun == true,
	})
	self:PersistActive()
	return true
end

function EarlyPrep:FlushDeferredPrepNotice()
	local deferred = self._deferredNotices
	if type(deferred) ~= "table" or type(deferred.bySender) ~= "table" then
		return false
	end
	local sync = SF.LootHelperSync
	if not sync or not sync.state or sync.state.active ~= true
		or sync.state.sessionId ~= deferred.sessionId
		or sync.state.profileId ~= deferred.profileId
	then
		self._deferredNotices = nil
		self:PersistActive()
		return false
	end
	local profilePresent = type(sync.FindLocalProfileById) == "function" and sync:FindLocalProfileById(deferred.profileId) ~= nil
	if EarlyPrep.PrepNoticeSenderState(profilePresent, false) == "defer" then
		return false
	end
	local pending = {}
	for sender, notice in pairs(deferred.bySender) do
		pending[#pending + 1] = {
			sender = sender,
			notice = notice,
		}
	end
	self._deferredNotices = nil
	local applied = false
	for i = 1, #pending do
		local item = pending[i]
		if not self:SenderInGroup(item.sender) then
			self:NoteReject(item.sender, "not_in_group")
		else
			local authorized = type(sync.IsSenderAuthorized) == "function" and sync:IsSenderAuthorized(deferred.profileId, item.sender) == true
			if EarlyPrep.PrepNoticeSenderState(true, authorized) == "apply" then
				local changed = self:ApplyHeartbeat(deferred.sessionId, deferred.profileId, {
					warned = EarlyPrep.WarnedArray(item.notice),
					raidCheckBegun = item.notice.raidCheckBegun == true,
				})
				if changed then
					applied = true
				end
			else
				self:NoteReject(item.sender, "unauthorized")
			end
		end
	end
	self:PersistActive()
	return applied
end

function EarlyPrep:AcceptRemotePrepNotice(sender, sessionId, profileId, prepNotice)
	if type(prepNotice) ~= "table" then
		return false
	end
	if not self:SenderInGroup(sender) then
		self:NoteReject(sender, "not_in_group")
		return false
	end
	local sync = SF.LootHelperSync
	local profilePresent = sync and type(sync.FindLocalProfileById) == "function" and sync:FindLocalProfileById(profileId) ~= nil
	local authorized = profilePresent and sync and type(sync.IsSenderAuthorized) == "function" and sync:IsSenderAuthorized(profileId, sender) == true
	local decision = EarlyPrep.PrepNoticeSenderState(profilePresent, authorized)
	if decision == "defer" then
		return self:DeferPrepNotice(sessionId, profileId, sender, prepNotice)
	end
	if decision ~= "apply" then
		return false
	end
	local changed = self:ApplyHeartbeat(sessionId, profileId, prepNotice)
	self:ObserveRemoteCoverage(prepNotice, sender)
	return changed
end

function EarlyPrep:ApplyHeartbeat(sessionId, profileId, prepNotice)
	if type(prepNotice) ~= "table" then
		return false
	end
	self:SyncNoticeToSession()
	if not self.notice or self.notice.sessionId ~= sessionId or self.notice.profileId ~= profileId then
		return false
	end
	local accepted, changed = EarlyPrep.ApplyNotice(self.notice, sessionId, profileId, {
		sessionId = sessionId,
		profileId = profileId,
		warned = prepNotice.warned,
		raidCheckBegun = prepNotice.raidCheckBegun == true,
	})
	if accepted and changed then
		self:PersistActive()
	end
	return changed and true or false
end

function EarlyPrep:BroadcastNotice(kind, memberId)
	local sync = SF.LootHelperSync
	local comm = SF.LootHelperComm
	if not sync or not sync.state or sync.state.active ~= true or not comm or type(comm.Send) ~= "function" or not sync.MSG then
		return false
	end
	local sessionId = self.notice and self.notice.sessionId
	local profileId = self.notice and self.notice.profileId
	if sessionId ~= sync.state.sessionId or profileId ~= sync.state.profileId then
		return false
	end
	if type(sync.IsSenderAuthorized) == "function" and type(sync._SelfId) == "function" then
		if not sync:IsSenderAuthorized(profileId, sync:_SelfId()) then
			return false
		end
	end
	local dist = type(sync.GetGroupDistribution) == "function" and sync:GetGroupDistribution() or nil
	if not dist then
		return false
	end
	local payload = {
		sessionId = sessionId,
		profileId = profileId,
		kind = kind,
		raidCheckBegun = self.notice.raidCheckBegun and true or false,
	}
	if kind == "warn" and EarlyPrep.ValidMemberId(memberId) then
		payload.memberId = memberId
	elseif kind == "snapshot" then
		payload.warned = EarlyPrep.WarnedArray(self.notice)
	end
	return comm:Send("CONTROL", sync.MSG.PREP_NOTICE, payload, dist, nil, "NORMAL") and true or false
end

function EarlyPrep:HandlePrepNotice(sender, payload)
	local sync = SF.LootHelperSync
	if not sync or not sync.state or sync.state.active ~= true or type(payload) ~= "table" then
		return
	end
	if payload.sessionId ~= sync.state.sessionId or payload.profileId ~= sync.state.profileId then
		self:NoteReject(sender, "session")
		return
	end
	if not self:SenderInGroup(sender) then
		self:NoteReject(sender, "not_in_group")
		return
	end
	local profilePresent = type(sync.FindLocalProfileById) == "function" and sync:FindLocalProfileById(payload.profileId) ~= nil
	local authorized = profilePresent and type(sync.IsSenderAuthorized) == "function" and sync:IsSenderAuthorized(payload.profileId, sender) == true
	local decision = EarlyPrep.PrepNoticeSenderState(profilePresent, authorized)
	if decision == "defer" then
		self:DeferPrepNotice(payload.sessionId, payload.profileId, sender, payload)
		return
	end
	if decision ~= "apply" then
		self:NoteReject(sender, "unauthorized")
		return
	end
	self:SyncNoticeToSession()
	local accepted, changed = EarlyPrep.ApplyNotice(self.notice, sync.state.sessionId, sync.state.profileId, payload)
	if not accepted then
		return
	end
	self:ObserveRemoteCoverage(payload, sender)
	if changed then
		self:PersistActive()
		DebugVerbose("Applied preparation notice from %s (kind=%s)", tostring(sender), tostring(payload.kind))
		self:Notify("prep_notice")
	end
end

function EarlyPrep:_Now()
	if GetTime then
		return GetTime()
	end
	return 0
end

function EarlyPrep:_CurrentCoordEpoch()
	local sync = SF.LootHelperSync
	if sync and sync.state then
		return tonumber(sync.state.coordEpoch)
	end
	return nil
end

function EarlyPrep:_SelfId()
	local sync = SF.LootHelperSync
	if sync and type(sync._SelfId) == "function" then
		return sync:_SelfId()
	end
	return nil
end

function EarlyPrep:_ClaimCount()
	local count = 0
	if type(self._claims) ~= "table" then
		return 0
	end
	for _ in pairs(self._claims) do
		count = count + 1
	end
	return count
end

function EarlyPrep:_FindClaim(memberId)
	if type(self._claims) ~= "table" or not EarlyPrep.ValidMemberId(memberId) then
		return nil, nil
	end
	local claim = self._claims[memberId]
	if type(claim) == "table" then
		return memberId, claim
	end
	for id, entry in pairs(self._claims) do
		if EarlyPrep.SameMember(id, memberId) and type(entry) == "table" then
			return id, entry
		end
	end
	return nil, nil
end

function EarlyPrep:ExpireWarningClaims(now)
	now = now or self:_Now()
	local epoch = self:_CurrentCoordEpoch()
	local changed = false
	if type(self._claims) == "table" then
		for memberId, claim in pairs(self._claims) do
			local expired = type(claim) ~= "table"
				or (type(claim.expiresAt) == "number" and claim.expiresAt <= now)
				or (epoch ~= nil and claim.coordEpoch ~= nil and claim.coordEpoch ~= epoch)
			if expired then
				self._claims[memberId] = nil
				changed = true
			end
		end
		if next(self._claims) == nil then
			self._claims = nil
		end
	end
	if type(self._pendingWhispers) == "table" then
		for requestId, pending in pairs(self._pendingWhispers) do
			if type(pending) ~= "table" or (type(pending.expiresAt) == "number" and pending.expiresAt <= now) then
				self._pendingWhispers[requestId] = nil
				changed = true
			end
		end
		if next(self._pendingWhispers) == nil then
			self._pendingWhispers = nil
		end
	end
	return changed
end

function EarlyPrep:ReleaseWarningClaim(memberId, reason)
	local key = select(1, self:_FindClaim(memberId))
	if not key then
		return false
	end
	self._claims[key] = nil
	if next(self._claims) == nil then
		self._claims = nil
	end
	DebugVerbose("Released warning claim for %s (%s)", tostring(memberId), tostring(reason or "release"))
	return true
end

function EarlyPrep:_NewClaimRequestId()
	self._claimSeq = (self._claimSeq or 0) + 1
	local selfId = self:_SelfId() or "local"
	return tostring(selfId) .. ":prepclaim:" .. tostring(self._claimSeq)
end

function EarlyPrep:_StorePendingWhisper(requestId, memberId, source, missing)
	if type(requestId) ~= "string" or requestId == "" or not EarlyPrep.ValidMemberId(memberId) then
		return false
	end
	self._pendingWhispers = self._pendingWhispers or {}
	local count = 0
	for _ in pairs(self._pendingWhispers) do
		count = count + 1
	end
	if count >= EarlyPrep.MAX_PENDING_WHISPERS and not self._pendingWhispers[requestId] then
		return false
	end
	self._pendingWhispers[requestId] = {
		memberId = memberId,
		source = source,
		missing = missing,
		expiresAt = self:_Now() + EarlyPrep.CLAIM_TTL_SECONDS,
	}
	return true
end

function EarlyPrep:_SendClaimRequest(memberId, source, missing)
	local sync = SF.LootHelperSync
	local comm = SF.LootHelperComm
	if not sync or not sync.state or sync.state.active ~= true or not sync.state.coordinator then
		return "denied"
	end
	if not comm or type(comm.Send) ~= "function" or not sync.MSG or not sync.MSG.PREP_WARN_CLAIM_REQ then
		return "denied"
	end
	local sessionId = self.notice and self.notice.sessionId
	local profileId = self.notice and self.notice.profileId
	if sessionId ~= sync.state.sessionId or profileId ~= sync.state.profileId then
		return "denied"
	end
	local requestId = self:_NewClaimRequestId()
	if not self:_StorePendingWhisper(requestId, memberId, source, missing) then
		return "denied"
	end
	local payload = {
		sessionId = sessionId,
		profileId = profileId,
		memberId = memberId,
		requestId = requestId,
		source = source,
	}
	local ok = comm:Send("CONTROL", sync.MSG.PREP_WARN_CLAIM_REQ, payload, "WHISPER", sync.state.coordinator, "NORMAL")
	if not ok then
		if self._pendingWhispers then
			self._pendingWhispers[requestId] = nil
		end
		return "denied"
	end
	return "pending"
end

function EarlyPrep:_GrantLocalClaim(memberId, claimer, requestId, source)
	self:ExpireWarningClaims()
	self:SyncNoticeToSession()
	local key, existing = self:_FindClaim(memberId)
	local epoch = self:_CurrentCoordEpoch()
	local decision, why = EarlyPrep.ClaimGrantDecision({
		alreadyWarned = EarlyPrep.IsWarned(self.notice, memberId),
		claimActive = existing ~= nil,
		claimerIsSender = existing and EarlyPrep.SameMember(existing.claimer, claimer) or false,
		epochMatch = true,
		atCap = self:_ClaimCount() >= EarlyPrep.MAX_CLAIMS,
	})
	if decision ~= "grant" then
		return false, why
	end
	local claimKey = key or memberId
	self._claims = self._claims or {}
	self._claims[claimKey] = {
		claimer = claimer,
		requestId = requestId,
		coordEpoch = epoch,
		expiresAt = self:_Now() + EarlyPrep.CLAIM_TTL_SECONDS,
		source = source,
	}
	return true, why
end

function EarlyPrep:_SendClaimAck(target, memberId, requestId, granted, reason)
	local sync = SF.LootHelperSync
	local comm = SF.LootHelperComm
	if not sync or not sync.state or not comm or type(comm.Send) ~= "function" then
		return false
	end
	if not sync.MSG or not sync.MSG.PREP_WARN_CLAIM_ACK then
		return false
	end
	local payload = {
		sessionId = sync.state.sessionId,
		profileId = sync.state.profileId,
		memberId = memberId,
		requestId = requestId,
		granted = granted == true,
		reason = reason,
		coordinator = sync.state.coordinator,
		coordEpoch = tonumber(sync.state.coordEpoch),
	}
	return comm:Send("CONTROL", sync.MSG.PREP_WARN_CLAIM_ACK, payload, "WHISPER", target, "NORMAL") and true or false
end

-- Acquire an exclusive coordinator claim before delivering a missing whisper.
-- Returns "granted", "pending", or "denied".
function EarlyPrep:BeginMissingWhisper(memberId, source, missing)
	if not EarlyPrep.ValidMemberId(memberId) then
		return "denied"
	end
	self:SyncNoticeToSession()
	self:ExpireWarningClaims()
	if EarlyPrep.IsWarned(self.notice, memberId) then
		return "denied"
	end
	if not EarlyPrep.WarningRecordable(self.notice, memberId) then
		return "denied"
	end
	local sync = SF.LootHelperSync
	if not sync or not sync.state or sync.state.active ~= true then
		return "denied"
	end
	local selfId = self:_SelfId()
	if type(selfId) ~= "string" or selfId == "" then
		return "denied"
	end
	if sync.state.isCoordinator == true then
		local granted = self:_GrantLocalClaim(memberId, selfId, self:_NewClaimRequestId(), source)
		return granted and "granted" or "denied"
	end
	return self:_SendClaimRequest(memberId, source, missing)
end

function EarlyPrep:HandlePrepWarnClaimRequest(sender, payload)
	local sync = SF.LootHelperSync
	if not sync or not sync.state or sync.state.active ~= true or sync.state.isCoordinator ~= true then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	if payload.sessionId ~= sync.state.sessionId or payload.profileId ~= sync.state.profileId then
		return
	end
	if not self:SenderInGroup(sender) then
		return
	end
	if type(sync.IsSenderAuthorized) == "function" and not sync:IsSenderAuthorized(payload.profileId, sender) then
		return
	end
	local memberId = payload.memberId
	local requestId = payload.requestId
	if not EarlyPrep.ValidMemberId(memberId) or type(requestId) ~= "string" or requestId == "" then
		return
	end
	local granted, why = self:_GrantLocalClaim(memberId, sender, requestId, payload.source)
	self:_SendClaimAck(sender, memberId, requestId, granted, why)
end

function EarlyPrep:HandlePrepWarnClaimAck(sender, payload)
	local sync = SF.LootHelperSync
	if not sync or not sync.state or sync.state.active ~= true or type(payload) ~= "table" then
		return
	end
	if payload.sessionId ~= sync.state.sessionId or payload.profileId ~= sync.state.profileId then
		return
	end
	if type(payload.coordinator) ~= "string" or payload.coordinator == "" then
		return
	end
	if not EarlyPrep.SameMember(sender, payload.coordinator) then
		return
	end
	if not EarlyPrep.SameMember(sender, sync.state.coordinator) then
		return
	end
	if type(payload.coordEpoch) == "number" then
		local localEpoch = tonumber(sync.state.coordEpoch)
		if localEpoch and payload.coordEpoch ~= localEpoch then
			return
		end
	end
	local requestId = payload.requestId
	local pending = type(self._pendingWhispers) == "table" and self._pendingWhispers[requestId] or nil
	if type(pending) ~= "table" then
		return
	end
	self._pendingWhispers[requestId] = nil
	if next(self._pendingWhispers) == nil then
		self._pendingWhispers = nil
	end
	if payload.granted ~= true then
		DebugVerbose("Warning claim denied for %s (%s)", tostring(pending.memberId), tostring(payload.reason or "denied"))
		return
	end
	self:CompleteClaimedWhisper(pending.memberId, pending.source, pending.missing)
end

function EarlyPrep:CompleteClaimedWhisper(memberId, source, missing)
	if not EarlyPrep.ValidMemberId(memberId) then
		return false
	end
	self:SyncNoticeToSession()
	if EarlyPrep.IsWarned(self.notice, memberId) then
		self:ReleaseWarningClaim(memberId, "already_warned")
		return false
	end
	local raidCheck = SF.RaidCheck
	if not raidCheck or type(raidCheck.DeliverMissingRequirementsWhisper) ~= "function" then
		self:ReleaseWarningClaim(memberId, "no_sender")
		return false
	end
	local profile = self:GetSessionProfile()
	local cfg = profile and type(profile.GetRaidCheckConfig) == "function" and profile:GetRaidCheckConfig() or nil
	local mode = source
	if mode ~= "pre" and mode ~= "raid" then
		mode = "pre"
	end
	local sent = raidCheck:DeliverMissingRequirementsWhisper(memberId, cfg, missing, profile, mode)
	if not sent then
		self:ReleaseWarningClaim(memberId, "send_failed")
		return false
	end
	return self:CommitWarned(memberId, source or mode)
end

function EarlyPrep:CommitWarned(memberId, source)
	self:SyncNoticeToSession()
	if not EarlyPrep.MarkWarned(self.notice, memberId) then
		self:ReleaseWarningClaim(memberId, "not_recordable")
		return false
	end
	self:ReleaseWarningClaim(memberId, "committed")
	self:PersistActive()
	DebugInfo("Recorded missing-requirements warning for %s (%s)", tostring(memberId), tostring(source or "unknown"))
	self:BroadcastNotice("warn", memberId)
	local sync = SF.LootHelperSync
	if not (sync and sync.state and sync.state.isCoordinator == true) then
		self:MarkOutboundPending()
	else
		self:ClearOutboundPending()
	end
	return true
end

function EarlyPrep:NoteRaidCheckBegun(sessionId, profileId)
	if type(sessionId) ~= "string" or sessionId == "" then
		return false
	end
	self:SyncNoticeToSession()
	if not self.notice or self.notice.sessionId ~= sessionId then
		return false
	end
	if type(profileId) == "string" and profileId ~= "" and self.notice.profileId and profileId ~= self.notice.profileId then
		return false
	end
	local changed = false
	if self.notice.raidCheckBegun ~= true then
		self.notice.raidCheckBegun = true
		changed = true
		self:PersistActive()
		DebugInfo("Raid Check began; early preparation stopped for session %s", tostring(sessionId))
		self:BroadcastNotice("raid_begun")
		local sync = SF.LootHelperSync
		if not (sync and sync.state and sync.state.isCoordinator == true) then
			self:MarkOutboundPending()
		else
			self:ClearOutboundPending()
		end
	end
	self:Refresh("raid_check_begun")
	return changed
end

function EarlyPrep:RememberNonWarning(memberId, stamp)
	if type(stamp) ~= "string" or stamp == "" or not EarlyPrep.ValidMemberId(memberId) then
		return
	end
	local skips = self._skipStamp
	if type(skips) ~= "table" then
		skips = {}
		self._skipStamp = skips
	end
	if skips[memberId] ~= nil then
		skips[memberId] = stamp
		return
	end
	local count = 0
	for _ in pairs(skips) do
		count = count + 1
		if count >= EarlyPrep.MAX_NOTICE_MEMBERS then
			return
		end
	end
	skips[memberId] = stamp
end

function EarlyPrep:CollectEligibleIds()
	local ids = {}
	local profile = self:GetSessionProfile()
	local groupIds
	if self._membershipPass and type(self._membershipSet) == "table" then
		groupIds = {}
		for id in pairs(self._membershipSet) do
			groupIds[#groupIds + 1] = id
		end
	else
		local raidCheck = SF.RaidCheck
		if not raidCheck or type(raidCheck.CollectGroupMemberIds) ~= "function" then
			return ids
		end
		groupIds = raidCheck:CollectGroupMemberIds() or {}
	end
	local seen = {}
	for i = 1, #groupIds do
		local id = groupIds[i]
		if not seen[id] and self:IsProfileMember(profile, id) then
			seen[id] = true
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

function EarlyPrep:EvaluateMember(memberId)
	if not self:ComputeWindow() then
		return false
	end
	if self:WasWarned(memberId) or not self:IsEligibleTarget(memberId) then
		return false
	end
	local raidCheck = SF.RaidCheck
	if not raidCheck or type(raidCheck.GetAuthoritativePreparation) ~= "function" then
		return false
	end
	local profile = self:GetSessionProfile()
	local cfg = profile and type(profile.GetRaidCheckConfig) == "function" and profile:GetRaidCheckConfig() or nil
	local stamp = nil
	if type(raidCheck.GetPreparationObservationStamp) == "function" then
		stamp = raidCheck:GetPreparationObservationStamp(memberId, cfg)
		if type(stamp) == "string" and self._skipStamp and self._skipStamp[memberId] == stamp then
			return false
		end
	end
	local result, why = raidCheck:GetAuthoritativePreparation(memberId, cfg)
	local decision = EarlyPrep.ObservationShouldWarn({
		eligible = true,
		inRaid = true,
		fresh = why == "fresh",
		complete = result and result.complete == true or false,
		prepared = result and result.prepared == true or false,
		alreadyWarned = false,
	})
	if not decision then
		self:RememberNonWarning(memberId, stamp)
		return false
	end
	if not self:ComputeWindow() or self:WasWarned(memberId) or not self:IsEligibleTarget(memberId) then
		return false
	end
	if why ~= "fresh" or type(result) ~= "table" or result.complete ~= true or result.prepared == true then
		self:RememberNonWarning(memberId, stamp)
		return false
	end
	if type(raidCheck.DeliverMissingRequirementsWhisper) ~= "function" then
		return false
	end
	self:SyncNoticeToSession()
	if not EarlyPrep.WarningRecordable(self.notice, memberId) then
		self:RememberNonWarning(memberId, stamp)
		return false
	end
	local claim = self:BeginMissingWhisper(memberId, "early", result.missing)
	if claim == "pending" then
		return false
	end
	if claim ~= "granted" then
		self:RememberNonWarning(memberId, stamp)
		return false
	end
	local sent = raidCheck:DeliverMissingRequirementsWhisper(memberId, cfg, result.missing, profile, "pre")
	if not sent then
		self:ReleaseWarningClaim(memberId, "send_failed")
		return false
	end
	self:CommitWarned(memberId, "early")
	return true
end

function EarlyPrep:OnMemberObserved(memberId)
	if self._evaluating or not self:ComputeWindow() then
		return
	end
	self._evaluating = true
	local ok, err = pcall(self.EvaluateMember, self, memberId)
	self._evaluating = false
	if not ok then
		error(err, 0)
	end
end

function EarlyPrep:OnBackgroundPass()
	if self._evaluating or not self:ComputeWindow() then
		return 0
	end
	self._evaluating = true
	self:BeginMembershipPass()
	-- End the membership pass even when evaluation throws, then surface the error.
	local ok, evaluatedOrErr = pcall(function()
		local ids = self:CollectEligibleIds()
		local evaluated = 0
		for i = 1, #ids do
			if not self:ComputeWindow() or evaluated >= EarlyPrep.MAX_NOTICE_MEMBERS then
				break
			end
			evaluated = evaluated + 1
			self:EvaluateMember(ids[i])
		end
		return evaluated
	end)
	self:EndMembershipPass()
	self._evaluating = false
	if not ok then
		error(evaluatedOrErr, 0)
	end
	return evaluatedOrErr
end

function EarlyPrep:Install()
	if not self._settingHooked then
		local store = SF.SettingsStore
		if store and type(store.RegisterCallback) == "function" then
			store:RegisterCallback(self.SETTING_PATH, function()
				self:Notify("setting")
			end)
			self._settingHooked = true
		end
	end
	if not self._impersonationHooked then
		local impersonation = SF.LootHelperImpersonation
		if impersonation and type(impersonation.RegisterCallback) == "function" then
			impersonation:RegisterCallback(function()
				self:Notify("impersonation")
			end)
			self._impersonationHooked = true
		end
	end
end

function EarlyPrep:Refresh(reason)
	if self._refreshing then
		return
	end
	self._refreshing = true
	-- Clear the refresh guard even when install, flush, or evaluation raises.
	local ok, err = pcall(function()
		self:Install()
		self:FlushDeferredPrepNotice()
		self:SyncNoticeToSession()
		self:ExpireWarningClaims()

		local open = self:ComputeWindow()
		local wasOpen = self._windowOpen and true or false
		local sync = SF.LootHelperSync
		local isCoordinator = sync and sync.state and sync.state.active == true and sync.state.isCoordinator == true
		local wasCoordinator = self._wasCoordinator and true or false
		self._windowOpen = open
		self._wasCoordinator = isCoordinator and true or false

		if open ~= wasOpen then
			DebugInfo("Early preparation %s (%s)", open and "active" or "inactive", tostring(reason or "refresh"))
		end
		if isCoordinator ~= wasCoordinator then
			DebugInfo("Coordinator responsibility %s (%s)", isCoordinator and "gained" or "lost", tostring(reason or "refresh"))
		end

		local raidCheck = SF.RaidCheck
		if raidCheck and type(raidCheck.SetBackgroundInspectEnabled) == "function" then
			local opts = nil
			if open then
				opts = { filter = EarlyPrep.EligibleFilter }
			end
			raidCheck:SetBackgroundInspectEnabled(open, self.CONSUMER_REASON, opts)
		end

		if isCoordinator and not wasCoordinator and self:HasShareableNotice() then
			if self:BroadcastNotice("snapshot") then
				self:ClearOutboundPending()
			end
		elseif self._outboundPending and reason == "heartbeat" then
			self:RetryOutboundNotice(reason)
		end
		-- Roster and heartbeat refreshes keep the window in sync. The inspect tick
		-- and a newly ready observation still evaluate members, so an already-open
		-- window does not scan the raid again on those reasons.
		local rosterOrHeartbeat = reason == "roster" or reason == "heartbeat"
		if open and (not wasOpen or not rosterOrHeartbeat) then
			self:OnBackgroundPass()
		end
	end)
	self._refreshing = false
	if not ok then
		error(err, 0)
	end
end

function EarlyPrep:Notify(reason)
	self:Refresh(reason)
end

if SF.LootHelperSync then
	function SF.LootHelperSync:HandlePrepNotice(sender, payload)
		local ep = SF.RaidEquipment and SF.RaidEquipment.EarlyPreparation
		if ep and ep.HandlePrepNotice then
			return ep:HandlePrepNotice(sender, payload)
		end
	end

	function SF.LootHelperSync:HandlePrepWarnClaimRequest(sender, payload)
		local ep = SF.RaidEquipment and SF.RaidEquipment.EarlyPreparation
		if ep and ep.HandlePrepWarnClaimRequest then
			return ep:HandlePrepWarnClaimRequest(sender, payload)
		end
	end

	function SF.LootHelperSync:HandlePrepWarnClaimAck(sender, payload)
		local ep = SF.RaidEquipment and SF.RaidEquipment.EarlyPreparation
		if ep and ep.HandlePrepWarnClaimAck then
			return ep:HandlePrepWarnClaimAck(sender, payload)
		end
	end
end
