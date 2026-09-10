local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

local function GetMemberById(profile, memberId)
    if not profile or type(memberId) ~= "string" or memberId == "" then
        return nil
    end
    if profile.getMemberByID then
        return profile:getMemberByID(memberId)
    elseif profile.GetMemberByID then
        return profile:GetMemberByID(memberId)
    end
    return nil
end


local function GetLogEventType(logTable)
    if type(logTable) ~= "table" then
        return nil
    end
    return logTable._eventType or logTable.eventType
end

local function GetLogEventData(logTable)
    if type(logTable) ~= "table" then
        return {}
    end
    return logTable._data or logTable.data or {}
end

function Sync:LiveRelationshipTouchesOwnerIdentity(profile, eventType, eventData, incomingLog)
    if type(profile) ~= "table" or type(eventData) ~= "table" then
        return false
    end
    local Identity = SF.LootHelperIdentity
    local logs = profile.GetLootLogs and profile:GetLootLogs() or profile._lootLogs or {}
    local owner = (profile.GetOwnerId and profile:GetOwnerId()) or profile._owner
    if Identity and Identity.PreOpTouchesOwner then
        local prefix = incomingLog and Identity.LogsBefore and Identity.LogsBefore(logs, incomingLog) or logs
        return Identity.PreOpTouchesOwner(prefix, eventType, eventData, owner)
    end
    local types = SF.LootLogEventTypes or {}
    if eventType == types.CHARACTER_LINK then
        if profile.IsEffectiveOwner and (
            profile:IsEffectiveOwner(eventData.memberA) or profile:IsEffectiveOwner(eventData.memberB)
        ) then
            return true
        end
        return false
    end
    if eventType == types.CHARACTER_UNLINK then
        return profile.IsEffectiveOwner and profile:IsEffectiveOwner(eventData.member) or false
    end
    return false
end

local function SenderIsEffectiveOwner(profile, sender)
    if type(profile) ~= "table" or type(sender) ~= "string" then
        return false
    end
    if profile.IsEffectiveOwner then
        return profile:IsEffectiveOwner(sender)
    end
    if profile.IsOwner then
        return profile:IsOwner(sender)
    end
    return false
end

function Sync:_QueuePendingLiveRelationship(profileId, sender, logTable)
    local sessionId = self.state and self.state.sessionId
    if type(sessionId) ~= "string" or sessionId == "" then
        return
    end
    if type(profileId) ~= "string" or profileId == "" then
        return
    end
    self._pendingLiveRelationship = self._pendingLiveRelationship or {}
    local list = self._pendingLiveRelationship[profileId] or {}
    local logId = self:_ExtractLogId(logTable)
    for i = 1, #list do
        if self:_ExtractLogId(list[i].logTable) == logId then
            return
        end
    end
    list[#list + 1] = {
        sender = sender,
        logTable = logTable,
        sessionId = sessionId,
        profileId = profileId,
    }
    self._pendingLiveRelationship[profileId] = list
end

function Sync:_PendingRelationshipCounterSets(profileId)
    local seen = {}
    local function add(logTable)
        local author, counter = self:_ExtractAuthorCounter(logTable)
        if type(author) == "string" and type(counter) == "number" then
            seen[author] = seen[author] or {}
            seen[author][counter] = true
        end
    end
    local pending = self._pendingLiveRelationship and self._pendingLiveRelationship[profileId]
    if type(pending) == "table" then
        for i = 1, #pending do
            add(pending[i].logTable)
        end
    end
    local inflight = self._liveRelationshipInFlight
    if type(inflight) == "table" then
        for i = 1, #inflight do
            add(inflight[i].logTable)
        end
    end
    return seen
end

function Sync:_ExtendContigWithPending(profileId, contig)
    contig = contig or {}
    local seen = self:_PendingRelationshipCounterSets(profileId)
    local Identity = SF.LootHelperIdentity
    for author, counters in pairs(seen) do
        local n = tonumber(contig[author]) or 0
        for existing, value in pairs(contig) do
            local match = existing == author
            if Identity and Identity.SameAuthor then
                match = Identity.SameAuthor(existing, author)
            elseif Identity and Identity.SamePlayer then
                match = Identity.SamePlayer(existing, author)
            end
            if match then
                local cur = tonumber(value) or 0
                if cur > n then
                    n = cur
                end
            end
        end
        while counters[n + 1] do
            n = n + 1
        end
        contig[author] = n
        if Identity and Identity.CanonicalAuthorKey then
            local key = Identity.CanonicalAuthorKey(author)
            if key then
                contig[key] = math.max(tonumber(contig[key]) or 0, n)
            end
        end
    end
    return contig
end

function Sync:_LiveRelationshipPredecessorState(profileId, logTable)
    local hasGap, gapFrom, gapTo = self:DetectGap(profileId, logTable)
    if hasGap then
        return false, nil, hasGap, gapFrom, gapTo
    end
    if type(self.ComputeContigAuthorMax) ~= "function" or type(self.ComputeMissingLogRequests) ~= "function" then
        return true, nil, false, nil, nil
    end
    local incomingAuthor, incomingCounter = self:_ExtractAuthorCounter(logTable)
    local contig = self:ComputeContigAuthorMax(profileId) or {}
    contig = self:_ExtendContigWithPending(profileId, contig)
    if type(incomingAuthor) == "string" and type(incomingCounter) == "number" then
        contig[incomingAuthor] = math.max(tonumber(contig[incomingAuthor]) or 0, incomingCounter)
    end
    local known = {}
    if type(self.state.authorMax) == "table" then
        for author, maxCounter in pairs(self.state.authorMax) do
            known[author] = tonumber(maxCounter) or 0
        end
    end
    local localMax = {}
    if type(self.ComputeAuthorMax) == "function" then
        localMax = self:ComputeAuthorMax(profileId) or {}
        for author, maxCounter in pairs(localMax) do
            known[author] = math.max(known[author] or 0, tonumber(maxCounter) or 0)
        end
    end
    local eventData = GetLogEventData(logTable)
    if type(eventData) == "table" and type(eventData.preOpAuthorMax) == "table" then
        for i = 1, #eventData.preOpAuthorMax do
            local entry = eventData.preOpAuthorMax[i]
            if type(entry) == "table" then
                local author = entry.author
                local maxCounter = tonumber(entry.counter)
                if type(author) == "string" and author ~= "" and maxCounter then
                    known[author] = math.max(known[author] or 0, maxCounter)
                end
            end
        end
    end
    if type(incomingAuthor) == "string" and type(incomingCounter) == "number" then
        known[incomingAuthor] = math.min(tonumber(known[incomingAuthor]) or incomingCounter, incomingCounter)
    end
    -- Logical catch-up uses contig vs writer-observed known heads, including
    -- preOpAuthorMax. Exact-spelling completeness must use advertised authorMax
    -- plus ComputeAuthorMax, and only for authors this event actually depends
    -- on. Scanning every advertised peer would defer an unrelated live LINK.
    local missing = self:ComputeMissingLogRequests(contig, known) or {}
    local rawForAlias = {}
    for author, maxCounter in pairs(localMax) do
        rawForAlias[author] = tonumber(maxCounter) or 0
    end
    if type(incomingAuthor) == "string" and type(incomingCounter) == "number" then
        rawForAlias[incomingAuthor] = math.max(tonumber(rawForAlias[incomingAuthor]) or 0, incomingCounter)
    end
    local aliasRemote = {}
    local advertised = self.state.authorMax or {}
    local Identity = SF.LootHelperIdentity
    local function takeAdvertisedAliases(author)
        if type(author) ~= "string" or author == "" then
            return
        end
        for auth, maxCounter in pairs(advertised) do
            maxCounter = tonumber(maxCounter)
            if type(auth) == "string" and maxCounter then
                local match = auth == author
                if Identity and Identity.SameAuthor then
                    match = Identity.SameAuthor(auth, author)
                end
                if match then
                    local prev = tonumber(aliasRemote[auth]) or 0
                    if maxCounter > prev then
                        aliasRemote[auth] = maxCounter
                    end
                end
            end
        end
    end
    takeAdvertisedAliases(incomingAuthor)
    if type(eventData) == "table" and type(eventData.preOpAuthorMax) == "table" then
        for i = 1, #eventData.preOpAuthorMax do
            local entry = eventData.preOpAuthorMax[i]
            if type(entry) == "table" then
                takeAdvertisedAliases(entry.author)
            end
        end
    end
    local aliasMissing = self:ComputeMissingLogRequests(contig, aliasRemote, rawForAlias)
    if type(aliasMissing) == "table" then
        for i = 1, #aliasMissing do
            missing[#missing + 1] = aliasMissing[i]
        end
    end
    if #missing > 0 then
        return false, missing, false, nil, nil
    end
    return true, nil, false, nil, nil
end

function Sync:_LiveRelationshipPredecessorReady(profileId, logTable)
    local ready = self:_LiveRelationshipPredecessorState(profileId, logTable)
    return ready
end

function Sync:_LiveRelationshipDomainValid(profile, eventType, eventData, incomingLog)
    local types = SF.LootLogEventTypes or {}
    local Validators = SF.LootLogValidators
    if eventType == types.CHARACTER_LINK then
        if not (Validators and Validators.ValidateCharacterLinkData and Validators.ValidateCharacterLinkData(eventData)) then
            return false
        end
        if not (profile.getMemberByID and profile:getMemberByID(eventData.memberA) and profile:getMemberByID(eventData.memberB)) then
            return false
        end
        return true
    end
    if eventType == types.CHARACTER_UNLINK then
        if not (Validators and Validators.ValidateCharacterUnlinkData and Validators.ValidateCharacterUnlinkData(eventData)) then
            return false
        end
        if not (profile.getMemberByID and profile:getMemberByID(eventData.member)) then
            return false
        end
        local Identity = SF.LootHelperIdentity
        local logs = profile.GetLootLogs and profile:GetLootLogs() or profile._lootLogs or {}
        local prefix = (Identity and Identity.LogsBefore and incomingLog) and Identity.LogsBefore(logs, incomingLog) or logs
        local group = Identity and Identity.ComponentMembers and Identity.ComponentMembers(prefix, eventData.member) or nil
        return type(group) == "table" and #group >= 2
    end
    return true
end

function Sync:FlushPendingLiveRelationshipLogs(profileId)
    if self._flushingLiveRelationship then
        return
    end
    local pending = self._pendingLiveRelationship and self._pendingLiveRelationship[profileId]
    if type(pending) ~= "table" or #pending == 0 then
        return
    end
    local Identity = SF.LootHelperIdentity
    if Identity and Identity.CompareLogs then
        table.sort(pending, function(a, b)
            return Identity.CompareLogs(a.logTable, b.logTable)
        end)
    end
    self._flushingLiveRelationship = true
    self._liveRelationshipInFlight = pending
    self._pendingLiveRelationship[profileId] = {}
    local currentSessionId = self.state and self.state.sessionId
    for i = 1, #pending do
        local item = pending[i]
        if type(item.sessionId) == "string" and item.sessionId == currentSessionId then
            self:HandleNewLog(item.sender, {
                sessionId = item.sessionId,
                profileId = profileId,
                log = item.logTable,
            })
        end
    end
    self._liveRelationshipInFlight = nil
    self._flushingLiveRelationship = nil
end


-- Function Called when a local admin creates a new log entry; broadcasts NEW_LOG to raid.
-- @param profileId string Current session profile id
-- @param logTable table A network-safe representation of the lootLog entry
-- @return nil
function Sync:BroadcastNewLog(profileId, logTable)
    local function fail(reason)
        if SF.Debug then
            SF.Debug:Warn("SYNC", "BroadcastNewLog blocked: %s", tostring(reason))
        end
        return false, reason
    end

    if not self.state.active then return fail("no active session") end
    if not self.state.sessionId then return fail("missing sessionId") end
    if type(profileId) ~= "string" or profileId == "" then return fail("missing profileId") end
    if self.state.profileId ~= profileId then return fail("wrong profile for session") end
    if not self:IsBulkTransferAllowed() then return fail("safe mode (bulk disabled)") end

    local dist = self:_EnforceGroupedSessionActive("BroadcastNewLog")
    if not dist then return fail("not in group/raid") end

    -- Owner-only events follow effective owner identity. Other live writes
    -- remain admin-authorized; coordinator trust does not bypass owner-identity.
    local me = self:_SelfId()
    local profile = self:FindLocalProfileById(profileId)
    local eventType = GetLogEventType(logTable)
    local eventData = GetLogEventData(logTable)
    local types = SF.LootLogEventTypes or {}
    local isRelationship = eventType == types.CHARACTER_LINK or eventType == types.CHARACTER_UNLINK
    local touchesOwnerIdentity = isRelationship and self:LiveRelationshipTouchesOwnerIdentity(profile, eventType, eventData, logTable)
    if eventType == types.LOOT_MODE_CHANGE then
        if not SenderIsEffectiveOwner(profile, me) then
            return fail("not authorized to broadcast owner-only NEW_LOG")
        end
    elseif isRelationship then
        if not self:IsSenderAuthorized(profileId, me) then
            return fail("not authorized to broadcast NEW_LOG")
        end
        local logAuthor = self:_ExtractAuthorCounter(logTable)
        if type(logTable) == "table" and logTable.GetAuthor then
            logAuthor = logTable:GetAuthor()
        end
        if not self:_SamePlayer(me, logAuthor) then
            return fail("relationship NEW_LOG author must match sender")
        end
        if touchesOwnerIdentity and not SenderIsEffectiveOwner(profile, me) then
            return fail("not authorized to broadcast owner-identity NEW_LOG")
        end
    elseif not self:IsSenderAuthorized(profileId, me) then
        return fail("not authorized to broadcast NEW_LOG")
    end

    -- Accept either a LootLog object or an already-serialized table
    if type(logTable) == "table" and logTable.ToTable then
        logTable = logTable:ToTable()
    end
    if type(logTable) ~= "table" then
        return fail("logTable must be a table (or LootLog instance)")
    end

    local payload = {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        log         = logTable,
    }

    if not SF.LootHelperComm then
        return fail("LootHelperComm not available")
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

    local ok, err = self:ValidateSessionPayload(payload)
    if not ok then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting NEW_LOG from %s: invalid session payload (%s)", tostring(sender), tostring(err or "unknown"))
        end
        return
    end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.log) ~= "table" then return end

    local profileId = payload.profileId
    local logTable = payload.log
    local eventData = GetLogEventData(logTable)
    local memberId = eventData.member
    local profileBefore = self:FindLocalProfileById(profileId)
    local oldPoints = 0
    if profileBefore and type(memberId) == "string" and memberId ~= "" then
        local beforeMember = GetMemberById(profileBefore, memberId)
        oldPoints = (beforeMember and tonumber(beforeMember.pointBalance)) or 0
    end

    -- If we don't have the profile yet, request snapshot
    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        if not self.state.isCoordinator then
            self:RequestProfileSnapshot("new-log")
        end
        return
    end

    -- Trust policy: coordinator or canonical admin for ordinary live writes.
    -- Relationship events always require baseline canonical admin before they
    -- can enter pending/repair state. Owner-identity authorization is applied
    -- by Identity.Replay against the ordered historical prefix so live receipt,
    -- bulk repair, and reload converge from the same logs.
    local eventType = GetLogEventType(logTable)
    local types = SF.LootLogEventTypes or {}
    local isRelationship = eventType == types.CHARACTER_LINK or eventType == types.CHARACTER_UNLINK
    local lootLog = logTable
    if isRelationship then
        if SF.LootLog and SF.LootLog.FromTable and getmetatable(logTable) ~= SF.LootLog then
            lootLog = select(1, SF.LootLog.FromTable(logTable, {
                allowUnknownEventType = false,
                requireFingerprint = true,
            }))
        end
        if not lootLog then
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring NEW_LOG from %s for profile %s: invalid relationship log."):format(tostring(sender), tostring(profileId)))
            end
            return
        end
        if lootLog.ToTable then
            logTable = lootLog:ToTable()
        end
        eventType = GetLogEventType(logTable) or eventType
        eventData = GetLogEventData(logTable)
        memberId = eventData.member or memberId
        if not self:_LiveRelationshipDomainValid(profile, eventType, eventData, logTable) then
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring NEW_LOG from %s for profile %s: invalid relationship payload."):format(tostring(sender), tostring(profileId)))
            end
            return
        end
        local logAuthor = self:_ExtractAuthorCounter(logTable)
        if not self:_SamePlayer(sender, logAuthor) then
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring NEW_LOG from %s for profile %s: relationship author must match sender."):format(tostring(sender), tostring(profileId)))
            end
            return
        end
        if not self:IsSenderAuthorized(profileId, sender) then
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring NEW_LOG from %s for profile %s: not an admin."):format(tostring(sender), tostring(profileId)))
            end
            return
        end
        local ready, missing, hasPredGap, predFrom, predTo = self:_LiveRelationshipPredecessorState(profileId, logTable)
        if not ready then
            self:_QueuePendingLiveRelationship(profileId, sender, logTable)
            if hasPredGap and type(predFrom) == "number" and type(predTo) == "number" then
                local author = (self:_ExtractAuthorCounter(logTable))
                if type(author) == "string" and author ~= "" and self.RequestGapRepair then
                    self:RequestGapRepair(profileId, author, predFrom, predTo, "new-log-gap")
                end
            elseif type(missing) == "table" and #missing > 0 and self.QueueRepairRanges then
                self:QueueRepairRanges(profileId, missing, {
                    mode = "missing",
                    reason = "live-relationship-predecessor",
                })
            end
            return
        end
    end

    if eventType == types.LOOT_MODE_CHANGE then
        if not SenderIsEffectiveOwner(profile, sender) then
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring NEW_LOG from %s for profile %s: not the owner."):format(tostring(sender), tostring(profileId)))
            end
            return
        end
    elseif not isRelationship and not self:_SamePlayer(sender, self.state.coordinator) then
        if not self:IsSenderAuthorized(profileId, sender) then
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring NEW_LOG from %s for profile %s: not an admin."):format(tostring(sender), tostring(profileId)))
            end
            return
        end
    end
    
    -- Dedupe by logId
    local logId = self:_ExtractLogId(logTable)
    if logId and profile._logIndex and profile._logIndex[logId] then
        local incomingFingerprint = logTable._fingerprint
        if type(incomingFingerprint) ~= "number" and SF.LootLog and SF.LootLog.ComputeFingerprintFromTable then
            incomingFingerprint = SF.LootLog.ComputeFingerprintFromTable(logTable)
        end
        local localFingerprint = profile.GetLogFingerprintById and profile:GetLogFingerprintById(logId) or nil

        if incomingFingerprint ~= nil and localFingerprint ~= nil and incomingFingerprint ~= localFingerprint then
            local author, counter = self:_ExtractAuthorCounter(logTable)
            local target = self.state.isCoordinator and sender or self.state.coordinator
            local isExternal = SF.LootLog and SF.LootLog.IsExternalLogTable and SF.LootLog.IsExternalLogTable(logTable)
            local isSequential = SF.LootLog and SF.LootLog.IsSequentialCounter and SF.LootLog.IsSequentialCounter(counter)
            if (not isExternal) and type(author) == "string" and isSequential then
                self:QueueRepairRanges(profileId, {
                    {
                        author = author,
                        fromCounter = counter,
                        toCounter = counter,
                        mode = "integrity",
                        preferredTarget = target,
                    }
                }, {
                    mode = "integrity",
                    reason = "new-log-mismatch",
                    preferredTarget = target,
                    expedite = true,
                })
            end
            if SF.Debug then
                SF.Debug:Warn("SYNC", "NEW_LOG fingerprint mismatch detected (id=%s, sender=%s, local=%s, remote=%s)",
                    tostring(logId), tostring(sender), tostring(localFingerprint), tostring(incomingFingerprint))
            end
            return
        end

        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Ignoring NEW_LOG duplicate (id=%s, sender=%s)", tostring(logId), tostring(sender))
        end
        return
    end
    
    -- Gap detection BEFORE merge
    local hasGap, gapFrom, gapTo = self:DetectGap(profileId, logTable)

    -- Apply a single live log through the profile insert path so in-order
    -- point/Attendance fan-out matches local writes. Do not use the batch
    -- merge+rebuild path for every Raid Check award. Relationship logs were
    -- already strictly deserialized above.
    if not isRelationship then
        if SF.LootLog and SF.LootLog.FromTable and getmetatable(logTable) ~= SF.LootLog then
            lootLog = select(1, SF.LootLog.FromTable(logTable, { allowUnknownEventType = true }))
        end
    end
    if not lootLog then
        return
    end
    local inserted = profile:AddLootLog(lootLog, { skipPermission = true, skipBroadcast = true })
    if not inserted then
        return
    end

    local Identity = SF.LootHelperIdentity
    local needsRebuild = true
    if Identity and Identity.RequiresProfileRebuild then
        needsRebuild = Identity.RequiresProfileRebuild(eventType)
    elseif Identity and Identity.CanFanOutBalance then
        needsRebuild = not Identity.CanFanOutBalance(eventType)
    end
    if needsRebuild then
        self:RebuildProfile(profileId, "live_update")
    elseif SF.LootHelperEvents and SF.LootHelperEvents.NotifyDataChanged then
        SF.LootHelperEvents:NotifyDataChanged("SYNC:LIVE", { profileId = profileId })
    end
    self:FlushPendingLiveRelationshipLogs(profileId)
    self:LogSessionPointsSummary(profileId, "live_update")

    if SF.Debug then
        local profileAfter = self:FindLocalProfileById(profileId)
        local memberAfter = GetMemberById(profileAfter, memberId)
        local newPoints = (memberAfter and tonumber(memberAfter.pointBalance)) or 0
        SF.Debug:Info("SYNC_POINTS", "Apply log (path=live_update member=%s old=%s delta=%s new=%s eventType=%s logId=%s)",
            tostring(memberId), tostring(oldPoints), tostring((tonumber(newPoints) or 0) - oldPoints), tostring(tonumber(newPoints) or 0),
            tostring(logTable._eventType or logTable.eventType), tostring(logId))
    end

    -- If we detected a gap, request missing logs
    if hasGap and type(gapFrom) == "number" and type(gapTo) == "number" then
        local author = (self:_ExtractAuthorCounter(logTable))
        if type(author) == "string" and author ~= "" then
            if SF.Debug then
                SF.Debug:Info("SYNC", "Gap detected on NEW_LOG (author=%s, gap=%d-%d, logId=%s); requesting repair",
                    tostring(author), gapFrom, gapTo, tostring(logId))
            end
            self:RequestGapRepair(profileId, author, gapFrom, gapTo, "new-log-gap")
        end
    elseif SF.Debug then
        SF.Debug:Verbose("SYNC", "Applied NEW_LOG without gap (id=%s, author=%s)", tostring(logId), tostring(self:_ExtractAuthorCounter(logTable)))
    end

    -- Keep local session authorMax fresh
    do
        local author, counter = self:_ExtractAuthorCounter(logTable)
        if type(author) == "string" and type(counter) == "number" then
            self.state.authorMax = self.state.authorMax or {}
            local prev = tonumber(self.state.authorMax[author]) or 0
            if counter > prev then
                self.state.authorMax[author] = counter
            end
        end
    end
end
