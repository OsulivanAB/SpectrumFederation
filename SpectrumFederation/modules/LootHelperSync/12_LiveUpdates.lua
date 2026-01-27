local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


-- Function Called when a local admin creates a new log entry; broadcasts NEW_LOG to raid.
-- @param profileId string Current session profile id
-- @param logTable table A network-safe representation of the lootLog entry
-- @return nil
function Sync:BroadcastNewLog(profileId, logTable)
    if not self.state.active then return false, "no active session" end
    if not self.state.sessionId then return false, "missing sessionId" end
    if type(profileId) ~= "string" or profileId == "" then return false, "missing profileId" end
    if self.state.profileId ~= profileId then return false, "wrong profile for session" end
    if not self:IsBulkTransferAllowed() then return false, "safe mode (bulk disabled)" end

    local dist = self:_EnforceGroupedSessionActive("BroadcastNewLog")
    if not dist then return false, "not in group/raid" end

    -- Only admins should be able to push live updates
    local me = self:_SelfId()
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
    self:RebuildProfile(profileId)

    -- If we detected a gap, request missing logs
    if hasGap and type(gapFrom) == "number" and type(gapTo) == "number" then
        local author = (self:_ExtractAuthorCounter(logTable))
        if type(author) == "string" and author ~= "" then
            self:RequestGapRepair(profileId, author, gapFrom, gapTo, "new-log-gap")
        end
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

