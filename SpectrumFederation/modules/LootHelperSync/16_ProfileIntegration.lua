local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


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
    profile._authorCounters = {}
    profile._members = {}
    profile._adminUsers = {}
    profile._activeProfile = false
    profile._profileId = profileMeta._profileId
    profile._profileName = profileMeta._profileName or "Imported Profile"

    return profile
end

-- Function Export a full snapshot for a profile, suitable for PROFILE_SNAPSHOT message.
-- @param profileId string Stable profile id
-- @return table|nil Snapshot payload or nil if profile not found
function Sync:BuildProfileSnapshot(profileId)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return nil end
    if not profile.ExportSnapshot then return nil end
    
    local snapshot = profile:ExportSnapshot()

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
function Sync:MergeLogs(profileId, logs)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return false end
    if type(logs) ~= "table" then return false end

    local inserted = profile:MergeLogTables(logs, { allowUnknownEventType = true })
    return inserted and inserted > 0
end

-- Function Rebuild derived state from logs (replay) for the given profile.
-- @param profileId string Stable profile id
-- @return nil
function Sync:RebuildProfile(profileId)
    if type(profileId) ~= "string" or profileId == "" then
        return false, "invalid profileId"
    end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        return false, "profile not found"
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
            if type(author) == "string" and type(counter) == "number" then
                local prev = profile._authorCounters[author] or 0
                if counter > prev then
                    profile._authorCounters[author] = counter
                end
            end
        end
    end

    -- 3) If profile is active, refresh cached/UI state (if your core uses this)
    if SF and SF.lootHelperDB and SF.lootHelperDB.activeProfileId == profileId
        and type(SF.SetActiveProfileById) == "function"
    then
        pcall(function()
            SF:SetActiveProfileById(profileId)
        end)
    end

    return true, nil
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
            return false
        end
    end

    -- Choose targets (helpers first, coordinator fallback)
    local targets = self:GetRequestTargets(self.state.helpers, self.state.coordinator)
    if not targets or #targets == 0 then return false end

    -- Prefer LOG_REQ if we are an admin; else use NEED_LOGS
    local me = self:_SelfId()
    local canLogReq = self:IsSenderAuthorized(profileId, me)
    local kind = canLogReq and "LOG_REQ" or "NEED_LOGS"

    local requestId = self:NewRequestId()

    local supportsEnc =
        (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
            and SF.SyncProtocol.GetSupportedEncodings()
            or nil

    -- fallback targets (exclude the first, since RegisterRequest adds it separately)
    local fallback = {}
    for i = 2, #targets do fallback[#fallback + 1] = targets[i] end

    local ok = self:RegisterRequest(requestId, kind, targets[1], {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        author      = author,
        fromCounter = gapFrom,
        toCounter   = gapTo,
        supportsEnc = supportsEnc,
        targets     = fallback,
    })

    if ok then
        self.state.gapRepair[key] = { lastAt = now, fromCounter = gapFrom, toCounter = gapTo }
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Gap repair requested via %s for %s: %s [%d-%d] (%s)",
                tostring(kind), tostring(profileId), tostring(author), gapFrom, gapTo, tostring(reason or "no reason"))
        end
    end

    return ok
end

