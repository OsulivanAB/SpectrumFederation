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

function EarlyPrep.MarkWarned(notice, memberId)
	if type(notice) ~= "table" or not EarlyPrep.ValidMemberId(memberId) then
		return false
	end
	notice.warned = notice.warned or {}
	if EarlyPrep.IsWarned(notice, memberId) then
		return false
	end
	local count = 0
	for _ in pairs(notice.warned) do
		count = count + 1
	end
	if count >= EarlyPrep.MAX_NOTICE_MEMBERS then
		return false
	end
	notice.warned[memberId] = true
	return true
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

function EarlyPrep:IsEligibleTarget(memberId)
	if not EarlyPrep.ValidMemberId(memberId) then
		return false
	end
	local profile = self:GetSessionProfile()
	if not self:IsProfileMember(profile, memberId) then
		return false
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
	if type(notice) ~= "table" or notice.sessionId ~= persisted.sessionId or notice.profileId ~= persisted.profileId then
		persisted.prepNotice = nil
		return
	end
	if not self:HasShareableNotice() then
		persisted.prepNotice = nil
		return
	end
	persisted.prepNotice = {
		sessionId = notice.sessionId,
		profileId = notice.profileId,
		raidCheckBegun = notice.raidCheckBegun and true or false,
		warned = EarlyPrep.WarnedArray(notice),
	}
end

function EarlyPrep:PersistActive()
	local db = (SpectrumFederationDB and SpectrumFederationDB.lootHelper) or SF.lootHelperDB
	if type(db) ~= "table" or type(db.syncSession) ~= "table" then
		return
	end
	self:WritePersisted(db.syncSession)
end

function EarlyPrep:RestorePersisted(persisted)
	if type(persisted) ~= "table" or type(persisted.prepNotice) ~= "table" then
		return
	end
	local saved = persisted.prepNotice
	if saved.sessionId ~= persisted.sessionId or saved.profileId ~= persisted.profileId then
		return
	end
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

function EarlyPrep:OnSessionReset(reason)
	DebugVerbose("Cleared early preparation session state (%s)", tostring(reason))
	self.notice = EarlyPrep.NewNotice()
	self._windowOpen = false
	self._wasCoordinator = false
	self._rejectLogged = {}
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
	if type(sync.IsSenderAuthorized) ~= "function" or not sync:IsSenderAuthorized(payload.profileId, sender) then
		self:NoteReject(sender, "unauthorized")
		return
	end
	self:SyncNoticeToSession()
	local accepted, changed = EarlyPrep.ApplyNotice(self.notice, sync.state.sessionId, sync.state.profileId, payload)
	if not accepted then
		return
	end
	if changed then
		self:PersistActive()
		DebugVerbose("Applied preparation notice from %s (kind=%s)", tostring(sender), tostring(payload.kind))
		self:Notify("prep_notice")
	end
end

function EarlyPrep:CommitWarned(memberId, source)
	self:SyncNoticeToSession()
	if not EarlyPrep.MarkWarned(self.notice, memberId) then
		return false
	end
	self:PersistActive()
	DebugInfo("Recorded missing-requirements warning for %s (%s)", tostring(memberId), tostring(source or "unknown"))
	self:BroadcastNotice("warn", memberId)
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
	end
	self:Refresh("raid_check_begun")
	return changed
end

function EarlyPrep:CollectEligibleIds()
	local raidCheck = SF.RaidCheck
	local ids = {}
	if not raidCheck or type(raidCheck.CollectGroupMemberIds) ~= "function" then
		return ids
	end
	local profile = self:GetSessionProfile()
	local groupIds = raidCheck:CollectGroupMemberIds() or {}
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
		return false
	end
	if not self:ComputeWindow() or self:WasWarned(memberId) or not self:IsEligibleTarget(memberId) then
		return false
	end
	if why ~= "fresh" or type(result) ~= "table" or result.complete ~= true or result.prepared == true then
		return false
	end
	if type(raidCheck.DeliverMissingRequirementsWhisper) ~= "function" then
		return false
	end
	local sent = raidCheck:DeliverMissingRequirementsWhisper(memberId, cfg, result.missing, profile, "pre")
	if not sent then
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
	self:EvaluateMember(memberId)
	self._evaluating = false
end

function EarlyPrep:OnBackgroundPass()
	if self._evaluating or not self:ComputeWindow() then
		return 0
	end
	self._evaluating = true
	local ids = self:CollectEligibleIds()
	local evaluated = 0
	for i = 1, #ids do
		if not self:ComputeWindow() or evaluated >= EarlyPrep.MAX_NOTICE_MEMBERS then
			break
		end
		evaluated = evaluated + 1
		self:EvaluateMember(ids[i])
	end
	self._evaluating = false
	return evaluated
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
	self:Install()
	self:SyncNoticeToSession()

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
		self:BroadcastNotice("snapshot")
	end
	if open then
		self:OnBackgroundPass()
	end
	self._refreshing = false
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
end
