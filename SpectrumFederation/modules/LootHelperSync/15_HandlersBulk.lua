local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


-- Function Handle AUTH_LOGS bulk response; merge logs and rebuild state if needed.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, author, logs =[...]}
-- @return nil
function Sync:HandleAuthLogs(sender, payload)
    -- Basic payload validation
    if type(payload) ~= "table" then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: invalid session payload", tostring(sender))
        end
        return
    end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.logs) ~= "table" then return end

    -- Require requestId for correlation
    if type(payload.requestId) ~= "string" or payload.requestId == "" then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: missing requestId", tostring(sender))
        end
        return
    end

    -- Lookup matching request
    local req = self.state.requests and self.state.requests[payload.requestId]
    if not req then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: no matching request for requestId %s", tostring(sender), tostring(payload.requestId))
        end
        return
    end

    -- Validate payload matches request metadata (for log requests)
    if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
        if type(payload.author) ~= "string" or payload.author == "" then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: missing author field", tostring(sender))
            end
            self:_RetryRequestSoon(req)
            return
        end
        if type(payload.fromCounter) ~= "number" or type(payload.toCounter) ~= "number" then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: missing or invalid counter fields", tostring(sender))
            end
            self:_RetryRequestSoon(req)
            return
        end

        -- Validate against request meta
        if req.meta then
            if req.meta.profileId and req.meta.profileId ~= payload.profileId then
                if SF.Debug then
                    SF.Debug:Warn("SYNC", "AUTH_LOGS payload mismatch for request %s: profileId expected=%s got=%s",
                        tostring(payload.requestId), tostring(req.meta.profileId), tostring(payload.profileId))
                end
                self:_RetryRequestSoon(req)
                return
            end
            if req.meta.author and req.meta.author ~= payload.author then
                if SF.Debug then
                    SF.Debug:Warn("SYNC", "AUTH_LOGS payload mismatch for request %s: author expected=%s got=%s",
                        tostring(payload.requestId), tostring(req.meta.author), tostring(payload.author))
                end
                self:_RetryRequestSoon(req)
                return
            end
            if req.meta.fromCounter and req.meta.fromCounter ~= payload.fromCounter then
                if SF.Debug then
                    SF.Debug:Warn("SYNC", "AUTH_LOGS payload mismatch for request %s: fromCounter expected=%d got=%d",
                        tostring(payload.requestId), tonumber(req.meta.fromCounter) or 0, tonumber(payload.fromCounter) or 0)
                end
                self:_RetryRequestSoon(req)
                return
            end
            if req.meta.toCounter and req.meta.toCounter ~= payload.toCounter then
                if SF.Debug then
                    SF.Debug:Warn("SYNC", "AUTH_LOGS payload mismatch for request %s: toCounter expected=%d got=%d",
                        tostring(payload.requestId), tonumber(req.meta.toCounter) or 0, tonumber(payload.toCounter) or 0)
                end
                self:_RetryRequestSoon(req)
                return
            end
        end
    end

    -- Trust validation: ALWAYS check sender is in group (both coordinator and member)
    if not self:IsRequesterInGroup(sender) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not in group", tostring(sender))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not in group."):format(sender))
        end
        return
    end

    -- Trust validation: Path-specific checks BEFORE merge
    if self.state.isCoordinator then
        -- Coordinator path: require sender is authorized admin
        if not self:IsSenderAuthorized(payload.profileId, sender) then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not authorized for profile %s (coordinator path)",
                    tostring(sender), tostring(payload.profileId))
            end
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not an admin of profile."):format(sender))
            end
            return
        end
        if SF.Debug then
            SF.Debug:Info("SYNC", "Accepting AUTH_LOGS from authorized admin %s (%d logs for %s [%d-%d])",
                tostring(sender), #payload.logs, tostring(payload.author),
                tonumber(payload.fromCounter) or 0, tonumber(payload.toCounter) or 0)
        end
    else
        -- Member path: require sender is coordinator or helper
        if not self:IsTrustedDataSender(sender) then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not a trusted sender (member path)", tostring(sender))
            end
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not a trusted sender."):format(sender))
            end
            return
        end
        -- Additional check: sender must be authorized admin
        if not self:IsSenderAuthorized(payload.profileId, sender) then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not an admin of profile (member path)", tostring(sender))
            end
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not an admin of profile."):format(sender))
            end
            return
        end
        if SF.Debug then
            local senderRole = (sender == self.state.coordinator) and "coordinator" or (self:IsHelper(sender) and "helper" or "unknown")
            SF.Debug:Info("SYNC", "Accepting AUTH_LOGS from %s as %s (%d logs for %s [%d-%d])",
                tostring(sender), senderRole, #payload.logs, tostring(payload.author),
                tonumber(payload.fromCounter) or 0, tonumber(payload.toCounter) or 0)
        end
    end

    -- All validation passed; proceed with merge
    -- Metrics: count logs received
    local recvLogs = (type(payload.logs) == "table") and #payload.logs or 0
    self:_MInc("sync.merge.auth_logs.logs_received_total", recvLogs)

    -- Metrics: measure merge duration
    local t0 = debugprofilestop and debugprofilestop() or nil
    local changed = self:MergeLogs(payload.profileId, payload.logs)
    if t0 then
        self:_MObserve("sync.merge.auth_logs.merge_ms", debugprofilestop() - t0)
    end

    if changed then
        -- Metrics: measure rebuild duration
        local t1 = debugprofilestop and debugprofilestop() or nil
        self:RebuildProfile(payload.profileId)
        if t1 then
            self:_MObserve("sync.merge.auth_logs.rebuild_ms", debugprofilestop() - t1)
        end
    end

    -- Range satisfaction check: only complete request if requested range is satisfied
    local requestSatisfied = false
    if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
        if req.meta and req.meta.author and req.meta.toCounter then
            local contig = self:_ComputeContigCounter(payload.profileId, req.meta.author)
            if contig >= req.meta.toCounter then
                requestSatisfied = true
                if SF.Debug then
                    SF.Debug:Info("SYNC", "Request %s satisfied: author=%s contig=%d >= requested=%d",
                        tostring(payload.requestId), tostring(req.meta.author), contig, req.meta.toCounter)
                end
            else
                -- Partial response: still missing logs
                if SF.Debug then
                    SF.Debug:Info("SYNC", "Request %s partial: author=%s contig=%d < requested=%d, will retry",
                        tostring(payload.requestId), tostring(req.meta.author), contig, req.meta.toCounter)
                end
                self:_RetryRequestSoon(req)
                return
            end
        else
            -- No meta to validate against; assume satisfied
            requestSatisfied = true
        end
    else
        -- Non-log request types: assume satisfied
        requestSatisfied = true
    end

    -- Complete request only if satisfied
    if requestSatisfied then
        self:CompleteRequest(payload.requestId)

        -- Admin convergence: only decrement if request satisfied
        if self.state.isCoordinator then
            local conv = self.state._adminConvergence
            if conv and payload.adminSyncId == conv.adminSyncId then
                if conv.pendingReq and conv.pendingReq[payload.requestId] then
                    conv.pendingReq[payload.requestId] = nil
                    conv.pendingCount = math.max(0, (conv.pendingCount or 1) - 1)

                    if conv.pendingCount == 0 then
                        self:_FinishAdminConvergence("complete")
                    end
                end
            end
        end
    end
end

-- Function Handle PROFILE_SNAPSHOT; import profile + logs then rebuild derived state.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, profileMeta, logs=[...], adminUsers=[...], ...}
-- @return nil
function Sync:HandleProfileSnapshot(sender, payload)
    if type(payload) ~= "table" then return end

    -- Must be for the current session
    local ok, err = self:ValidateSessionPayload(payload)
    if not ok then return end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.snapshot) ~= "table" then return end

    -- Trust policy: accept from coordinator or helper
    if not self:IsTrustedDataSender(sender) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting PROFILE_SNAPSHOT from %s: not a trusted sender", tostring(sender))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring PROFILE_SNAPSHOT from %s: not a trusted sender."):format(sender))
        end
        return
    end

    -- Safety: sender must be in group
    if not self:IsRequesterInGroup(sender) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting PROFILE_SNAPSHOT from %s: not in group", tostring(sender))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring PROFILE_SNAPSHOT from %s: not in group."):format(sender))
        end
        return
    end

    local senderRole =
        (self.state.coordinator and self:_SamePlayer(sender, self.state.coordinator)) and "coordinator"
        or (self:IsHelper(sender) and "helper" or "unknown")
    if SF.Debug then
        SF.Debug:Info("SYNC", "Accepting PROFILE_SNAPSHOT from %s as %s (profile: %s)",
            tostring(sender), senderRole, tostring(payload.profileId))
    end

    -- Validate snapshot
    if SF.LootProfile and SF.LootProfile.ValidateSnapshot then
        local okSnap, snapErr = SF.LootProfile.ValidateSnapshot(payload.snapshot)
        if not okSnap then
            if SF.PrintWarning then
                SF:PrintWarning(("PROFILE_SNAPSHOT invalid: %s"):format(snapErr or "unknown"))
            end
            return
        end
    end

    -- Ensure payload.profileId matches snapshot meta profileId
    local meta = payload.snapshot.meta
    if not meta or type(meta._profileId) ~= "string" then return end
    if payload.profileId ~= meta._profileId then
        if SF.PrintWarning then
            SF:PrintWarning(("PROFILE_SNAPSHOT mismatch: payload.profileId=%s meta._profileId=%s"):format(
                tostring(payload.profileId), tostring(meta._profileId)))
        end
        return
    end

    -- Metrics: count logs received from snapshot
    local snapshotLogs = payload.snapshot.logs or payload.snapshot.lootLogs or payload.snapshot._lootLogs
    local recvLogs = (type(snapshotLogs) == "table") and #snapshotLogs or 0
    self:_MInc("sync.merge.profile_snapshot.logs_received_total", recvLogs)

    -- Ensure DB exists
    SF.lootHelperDB = SF.lootHelperDB or { profiles = {}, activeProfileId = nil }
    SF.lootHelperDB.profiles = SF.lootHelperDB.profiles or {}

    local profileId = payload.profileId
    local profile = self:FindLocalProfileById(profileId)
    local isNew = false

    if not profile then
        profile = self:CreateProfileFromMeta(meta)
        if not profile then return end
        isNew = true
    end

    -- Metrics: measure import duration
    local t0 = debugprofilestop and debugprofilestop() or nil
    local okImport, inserted, importErr = profile:ImportSnapshot(payload.snapshot, { allowUnknownEventType = true })
    if t0 then
        self:_MObserve("sync.merge.profile_snapshot.import_ms", debugprofilestop() - t0)
    end

    if not okImport then
        if SF.PrintWarning then
            SF:PrintWarning(("PROFILE_SNAPSHOT import failed: %s"):format(importErr or "unknown"))
        end
        return
    end

    -- Store new profile in canonical map (keyed by profileId)
    if isNew then
        SF.lootHelperDB.profiles[profileId] = profile
        if SF.Debug then
            SF.Debug:Info("SYNC", "Imported new profile: %s (ID: %s)", 
                profile:GetProfileName() or "Unknown", profileId)
        end
    end

    -- Metrics: measure rebuild duration
    local t1 = debugprofilestop and debugprofilestop() or nil
    self:RebuildProfile(profileId)
    if t1 then
        self:_MObserve("sync.merge.profile_snapshot.rebuild_ms", debugprofilestop() - t1)
    end

    -- Set as active profile (use profileId now)
    if SF.SetActiveProfileById then
        SF:SetActiveProfileById(profileId)
    end

    if type(payload.requestId) == "string" and payload.requestId ~= "" then
        self:CompleteRequest(payload.requestId)
    end

    -- Clear profile request dedupe marker on successful import
    if self.state._profileReqInFlight == self.state.sessionId then
        self.state._profileReqInFlight = nil
    end

    if SF.PrintInfo then
        SF:PrintInfo(("Imported PROFILE_SNAPSHOT %s (%d new logs)"):format(
            profile:GetProfileName() or profileId,
            inserted or 0))
    end

    -- Now that we actually have the profile, run the normal sync assessment path:
    -- - if missing logs, it will Request MissingLogs()
    -- - if fully synced, it will whisper HAVE_PROFILE to coordinator
    self:RunAfter(0, function()
       if not self.state.active then return end
       if self.state.sessionId ~= payload.sessionId then return end
       if self.state.profileId ~= profileId then return end
       if self.state.isCoordinator then return end
       self:SendJoinStatus()
    end)
end

