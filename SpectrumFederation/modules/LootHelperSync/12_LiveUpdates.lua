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

    -- Only admins should be able to push live updates
    local me = self:_SelfId()
    if not self:IsSenderAuthorized(profileId, me) then
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
    local eventData = logTable._data or logTable.data or {}
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

    -- Trust policy: accept from coordinator; otherwise require sender is an admin
    if not self:_SamePlayer(sender, self.state.coordinator) then
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
            if type(author) == "string" and type(counter) == "number" then
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

    -- Apply log
    local inserted = self:MergeLogs(profileId, { logTable })
    if not inserted then
        return
    end

    -- Update UI / derived state
    self:RebuildProfile(profileId, "live_update")
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
