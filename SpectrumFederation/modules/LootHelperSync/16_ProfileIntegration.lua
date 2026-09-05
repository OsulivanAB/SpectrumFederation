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

function Sync:ComputeWindowMismatchRequests(profileId, remoteSummary, localContig)
    local mismatches = {}
    if type(remoteSummary) ~= "table" then return mismatches end

    local localSummary = self:ComputeAuthorWindowSummary(profileId)
    localContig = localContig or self:ComputeContigAuthorMax(profileId)

    local localByAuthor = {}
    for author, windows in pairs(localSummary or {}) do
        if type(windows) == "table" then
            local indexed = {}
            for _, row in ipairs(windows) do
                if type(row) == "table" and type(row.fromCounter) == "number" then
                    indexed[row.fromCounter] = row
                end
            end
            localByAuthor[author] = indexed
        end
    end

    for author, windows in pairs(remoteSummary) do
        if type(author) == "string" and type(windows) == "table" then
            local authorContig = tonumber(localContig and localContig[author]) or 0
            local indexed = localByAuthor[author] or {}
            for _, remoteWindow in ipairs(windows) do
                if type(remoteWindow) == "table"
                    and type(remoteWindow.fromCounter) == "number"
                    and type(remoteWindow.toCounter) == "number"
                    and authorContig >= remoteWindow.toCounter
                then
                    local localWindow = indexed[remoteWindow.fromCounter]
                    local localCount = localWindow and tonumber(localWindow.count) or 0
                    local localChecksum = localWindow and tonumber(localWindow.checksum) or nil
                    local remoteCount = tonumber(remoteWindow.count) or 0
                    local remoteChecksum = tonumber(remoteWindow.checksum) or nil

                    if (not localWindow)
                        or localCount ~= remoteCount
                        or localChecksum ~= remoteChecksum
                    then
                        mismatches[#mismatches + 1] = {
                            author = author,
                            fromCounter = remoteWindow.fromCounter,
                            toCounter = remoteWindow.toCounter,
                            mode = "integrity",
                        }
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

    return true, nil
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
        if a == author then
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

    for _, log in ipairs(self:_GetProfileLootLogs(profile)) do
        local a = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
        local c = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
        c = tonumber(c)

        if type(a) == "string" and a ~= "" and c and c >= 1 then
            c = math.floor(c)
            local set = seenByAuthor[a]
            if not set then
                set = {}
                seenByAuthor[a] = set
            end
            set[c] = true
        end
    end

    local contig = {}
    for author, set in pairs(seenByAuthor) do
        local n = 0
        while set[n + 1] do
            n = n + 1
        end
        contig[author] = n
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
-- @return boolean True if overlapping request exists, false otherwise
-- Returns true only if an existing request fully covers [fromCounter, toCounter]
function Sync:_HasOutstandingLogRangeRequest(profileId, author, fromCounter, toCounter)
    if type(self.state) ~= "table" then return false end
    if type(self.state.requests) ~= "table" then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end
    if type(author) ~= "string" or author == "" then return false end

    fromCounter = tonumber(fromCounter)
    toCounter = tonumber(toCounter)
    if not fromCounter or not toCounter then return false end

    for _, req in pairs(self.state.requests) do
        if type(req) == "table" and type(req.meta) == "table" then
            if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
                local m = req.meta
                if m.profileId == profileId and m.author == author then
                    local f = tonumber(m.fromCounter)
                    local t = tonumber(m.toCounter)
                    if f and t then
                        -- Suppress only if existing request fully covers new desired range
                        if f <= fromCounter and t >= toCounter then
                            return true
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
            and not self:_HasOutstandingLogRangeRequest(profileId, range.author, range.fromCounter, range.toCounter)
        then
            local fallback = {}
            for i = 2, #targets do
                fallback[#fallback + 1] = targets[i]
            end

            local requestId = self:NewRequestId()
            local kind = (self.state.isCoordinator or self:CanSelfCoordinate(profileId)) and "LOG_REQ" or "NEED_LOGS"
            local ok = self:RegisterRequest(requestId, kind, targets[1], {
                sessionId = self.state.sessionId,
                profileId = profileId,
                author = range.author,
                fromCounter = range.fromCounter,
                toCounter = range.toCounter,
                supportsEnc = supportsEnc,
                targets = fallback,
                integrityRepair = true,
                reason = reason,
                preferredTarget = preferredTarget,
                backgroundRepair = opts.backgroundRepair == true,
                queueAttempts = tonumber(opts.queueAttempts) or 0,
            })
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
    self.state._pendingMutationAdvertisement = {
        profileId = profileId,
        ranges = type(ranges) == "table" and ranges or {},
        reason = reason,
    }
    return true
end
