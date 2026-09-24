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

    local ok, err = self:ValidateSessionPayload(payload)
    if not ok then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: invalid session payload (%s)", tostring(sender), tostring(err or "unknown"))
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

    -- Trust validation: Path-specific checks BEFORE merge.
    -- Revoked responders already removed from a live request are stale, not a new incident.
    -- A still-authorized responder who was sent this request remains acceptable after a
    -- routing-only helper change. Future sends use the refreshed target list.
    local disposition = "unauthorized"
    if self._ClassifyPrivilegedResponse then
        local classifyOpts = {
            coordinatorAcceptsAdmins = true,
            expectedKinds = {
                NEED_LOGS = true,
                LOG_REQ = true,
                ADMIN_LOG_REQ = true,
            },
        }
        if self._CoordinatorNeedsCatchUp and self:_CoordinatorNeedsCatchUp(sender)
            and self._CatchUpLogsProveGrant
        then
            classifyOpts.catchUpProven = self:_CatchUpLogsProveGrant(sender, payload.logs) == true
        end
        disposition = self:_ClassifyPrivilegedResponse(sender, payload.profileId, req, classifyOpts)
    elseif self.state.isCoordinator then
        disposition = self:IsSenderAuthorized(payload.profileId, sender) and "accept" or "unauthorized"
    elseif not self:IsTrustedDataSender(sender) then
        disposition = "untrusted"
    elseif not self:IsSenderAuthorized(payload.profileId, sender) then
        disposition = "unauthorized"
    else
        disposition = "accept"
    end

    if disposition == "mismatch" then
        self:_NoteResponseKindMismatch(req, sender,
            ("Ignoring AUTH_LOGS from %s: response does not match the request."):format(tostring(sender)))
        return
    end
    if disposition == "unproven" then
        self:_NoteUnprovenCatchUp(req, sender,
            ("Ignoring AUTH_LOGS from %s: coordinator authority is not established yet."):format(tostring(sender)))
        return
    end
    if disposition == "stale" then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Ignoring stale AUTH_LOGS from %s for request %s after authorization reconcile",
                tostring(sender), tostring(payload.requestId))
        end
        return
    end
    if disposition == "unauthorized" then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not an admin of profile %s",
                tostring(sender), tostring(payload.profileId))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not an admin of profile."):format(sender))
        end
        return
    end
    if disposition == "untrusted" then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not a trusted sender (member path)", tostring(sender))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not a trusted sender."):format(sender))
        end
        return
    end
    if SF.Debug then
        local senderRole = (self:_SamePlayer(sender, self.state.coordinator) and "coordinator")
            or (self:IsHelper(sender) and "helper" or "inflight")
        SF.Debug:Info("SYNC", "Accepting AUTH_LOGS from %s as %s (%d logs for %s [%d-%d])",
            tostring(sender), senderRole, #payload.logs, tostring(payload.author),
            tonumber(payload.fromCounter) or 0, tonumber(payload.toCounter) or 0)
    end

    -- All validation passed; proceed with merge
    -- Metrics: count logs received
    local recvLogs = (type(payload.logs) == "table") and #payload.logs or 0
    self:_MInc("sync.merge.auth_logs.logs_received_total", recvLogs)
    
    -- Rec 4: Verify received logs match requested range before merge
    if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
        if req.meta and req.meta.author and req.meta.fromCounter and req.meta.toCounter then
            local requestedAuthor = req.meta.author
            local requestedFrom = req.meta.fromCounter
            local requestedTo = req.meta.toCounter
            
            -- Verify all received logs are for the correct author and within requested range
            local exactRepair = self:_IsExactAuthorRepair(req.meta)
            for _, logTable in ipairs(payload.logs) do
                -- An attached admin grant may name another author. It is proof,
                -- not a reason to reject the requested window. A trusted admin
                -- may also attach the catch-up coordinator's grant outside that window.
                local grantProof = self._LogAdminGrantState and self:_LogAdminGrantState(logTable, sender)
                if not grantProof and self._CoordinatorNeedsCatchUp and self.state
                    and self:_CoordinatorNeedsCatchUp(self.state.coordinator)
                    and self:IsSenderAuthorized(payload.profileId, sender)
                    and not self:_CoordinatorNeedsCatchUp(sender)
                then
                    grantProof = self:_LogAdminGrantState(logTable, self.state.coordinator) ~= nil
                end
                if not grantProof then
                    local logAuthor = logTable._author or logTable.author
                    local logCounter = logTable._counter or logTable.counter

                    local authorMatches = self:_AuthorMatchesRepairRequest(logAuthor, requestedAuthor, exactRepair)
                    if not authorMatches then
                        if SF.Debug then
                            SF.Debug:Warn("SYNC", "Rejecting AUTH_LOGS: log author %s doesn't match requested %s (exactAuthor=%s)",
                                tostring(logAuthor), tostring(requestedAuthor), tostring(exactRepair))
                        end
                        if self._RetryRequestSoon then
                            self:_RetryRequestSoon(req)
                        end
                        return
                    end

                    if type(logCounter) == "number" and (logCounter < requestedFrom or logCounter > requestedTo) then
                        if SF.Debug then
                            SF.Debug:Warn("SYNC", "Rejecting AUTH_LOGS: log counter %d outside requested range [%d-%d]",
                                logCounter, requestedFrom, requestedTo)
                        end
                        if self._RetryRequestSoon then
                            self:_RetryRequestSoon(req)
                        end
                        return
                    end
                end
            end
        end
    end

    -- Metrics: measure merge duration
    local t0 = debugprofilestop and debugprofilestop() or nil
    -- Stored coordinator is not enough. Replacing rows requires a canonical admin.
    -- A catch-up packet may insert the grant, but it must not overwrite history
    -- until that grant is already in the local profile.
    local senderIsCanonicalAdmin = self:IsSenderAuthorized(payload.profileId, sender) == true
    local function replaceAllowed()
        return (req.meta and req.meta.integrityRepair == true)
            and senderIsCanonicalAdmin
            and (
                self.state.isCoordinator
                or self:_SamePlayer(sender, self.state.coordinator)
            )
    end
    local allowReplaceExisting = replaceAllowed()
    local logsToMerge = {}
    for _, logTable in ipairs(payload.logs) do
        local logAuthor = logTable._author or logTable.author
        local logCounter = tonumber(logTable._counter or logTable.counter)
        local inRange = true
        if req.meta and type(req.meta.author) == "string"
            and type(req.meta.fromCounter) == "number" and type(req.meta.toCounter) == "number"
            and self._AuthorMatchesRepairRequest
        then
            local exactRepair = self:_IsExactAuthorRepair(req.meta)
            inRange = self:_AuthorMatchesRepairRequest(logAuthor, req.meta.author, exactRepair)
                and not (type(logCounter) == "number"
                    and (logCounter < req.meta.fromCounter or logCounter > req.meta.toCounter))
        end
        if inRange then
            logsToMerge[#logsToMerge + 1] = logTable
        end
    end
    local grantChanged = false
    -- A canonical admin can insert the coordinator grant this client missed.
    -- The successor still cannot supply that missing row as their own proof.
    if senderIsCanonicalAdmin and self._LogAdminGrantState and self._CoordinatorNeedsCatchUp
        and self.state and self:_CoordinatorNeedsCatchUp(self.state.coordinator)
        and not self:_CoordinatorNeedsCatchUp(sender)
        and self._LocalCatchUpGrantStored and not self:_LocalCatchUpGrantStored(self.state.coordinator)
    then
        local trustedGrantLogs = {}
        for _, logTable in ipairs(payload.logs) do
            if self:_LogAdminGrantState(logTable, self.state.coordinator) then
                trustedGrantLogs[#trustedGrantLogs + 1] = logTable
            end
        end
        if #trustedGrantLogs > 0 then
            local changedGrant = self:MergeLogs(payload.profileId, trustedGrantLogs, {
                allowReplaceExisting = false,
                allowMainSwapFingerprintNormalize = true,
            })
            -- The shared rebuild below runs when this insert changes history.
            -- Rebuilding here as well replays the whole profile twice.
            grantChanged = changedGrant and true or false
        end
    end
    local catchUpMerge = (not senderIsCanonicalAdmin)
        and self._CoordinatorNeedsCatchUp and self:_CoordinatorNeedsCatchUp(sender)
    if catchUpMerge and self._LogAdminGrantState then
        local grantLogs, contentLogs = {}, {}
        -- Only the locally matched grant may be merged. A second grant or
        -- revocation in the same payload is sender-supplied and is dropped.
        local provenGrant = self._CatchUpProvenGrantLog and self:_CatchUpProvenGrantLog(sender, payload.logs) or nil
        for _, logTable in ipairs(payload.logs) do
            if self:_LogAdminGrantState(logTable, sender) then
                if provenGrant and self:_GrantRowsMatch(logTable, provenGrant) then
                    grantLogs[#grantLogs + 1] = logTable
                end
            else
                contentLogs[#contentLogs + 1] = logTable
            end
        end
        if #grantLogs > 0 then
            local changedGrant = self:MergeLogs(payload.profileId, grantLogs, {
                allowReplaceExisting = false,
                allowMainSwapFingerprintNormalize = true,
            })
            grantChanged = changedGrant and true or false
        end
        -- The grant used as proof is already local. Rebuild even when the merge
        -- inserts nothing, so a stale admin list can absorb that stored row
        -- before this packet's other logs are considered.
        if self.RebuildProfile then
            self:RebuildProfile(payload.profileId, "auth_logs")
        end
        -- The requested window is merged only after the grant is local.
        -- Until then this packet cannot insert or replace the gap rows.
        if self:IsSenderAuthorized(payload.profileId, sender) then
            senderIsCanonicalAdmin = true
            allowReplaceExisting = replaceAllowed()
            logsToMerge = contentLogs
        else
            logsToMerge = {}
            allowReplaceExisting = false
        end
    end
    -- Current-session non-coordinator BIS_OUTCOME rows are not stored. Their
    -- counters stay in session memory so this repair can still complete.
    -- Historical rows and direct MergeLogTables / snapshot import are kept.
    if self._PartitionRepairBisOutcomes and type(logsToMerge) == "table" and #logsToMerge > 0 then
        logsToMerge = self:_PartitionRepairBisOutcomes(payload.profileId, logsToMerge)
    end
    local changed, mergeDetails = false, { inserted = 0, replaced = 0, mismatchCount = 0 }
    if type(logsToMerge) == "table" and #logsToMerge > 0 then
        changed, mergeDetails = self:MergeLogs(payload.profileId, logsToMerge, {
            allowReplaceExisting = allowReplaceExisting,
            allowMainSwapFingerprintNormalize = true,
        })
    end
    if grantChanged then
        changed = true
    end
    if t0 then
        self:_MObserve("sync.merge.auth_logs.merge_ms", debugprofilestop() - t0)
    end

    if mergeDetails and mergeDetails.mismatchCount and mergeDetails.mismatchCount > 0 and SF.Debug then
        SF.Debug:Warn("SYNC", "AUTH_LOGS merge saw %d fingerprint mismatches for request %s (allowReplace=%s)",
            mergeDetails.mismatchCount, tostring(payload.requestId), tostring(allowReplaceExisting))
    end

    if changed or (mergeDetails and (mergeDetails.replaced or 0) > 0) then
        -- Metrics: measure rebuild duration
        local t1 = debugprofilestop and debugprofilestop() or nil
        self:RebuildProfile(payload.profileId, "auth_logs")
        if t1 then
            self:_MObserve("sync.merge.auth_logs.rebuild_ms", debugprofilestop() - t1)
        end

        if self.state.isCoordinator
            and payload.profileId == self.state.profileId
            and req.meta
            and req.meta.integrityRepair == true
        then
            self.state.authorWindowSummary = self:ComputeAuthorWindowSummary(payload.profileId)
            self:BroadcastSessionHeartbeat()
        end
    end

    -- Range satisfaction check: only complete request if requested range is satisfied
    local requestSatisfied = false
    if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
        if req.meta and req.meta.author and req.meta.toCounter then
            local exactRepair = self:_IsExactAuthorRepair(req.meta)
            if exactRepair then
                -- A proof-bearing AUTH_LOGS payload can establish that the
                -- advertiser's filled set is present locally even when the
                -- receiver also retains extra valid rows in the same window.
                if self._ProveAdvertisedWindowsFromAuthLogs then
                    self:_ProveAdvertisedWindowsFromAuthLogs(payload.profileId, req.meta, payload.logs)
                end
                -- Empty AUTH_LOGS, SameAuthor siblings, later-window rows,
                -- and incomplete integrity subsets must not complete
                -- exact-author repairs. Coordinator fallback has to keep
                -- running until the requested window is actually filled.
                -- Members late-bind coordinator-advertised windows onto
                -- in-flight exact requests that were queued without proof.
                self:_BindSessionWindowEvidence({ req.meta })
                requestSatisfied = self:_ExactAuthorRangeSatisfied(
                    payload.profileId,
                    req.meta.author,
                    req.meta.fromCounter or 1,
                    req.meta.toCounter,
                    {
                        integrityRepair = req.meta.integrityRepair == true,
                        expectedCount = req.meta.expectedCount,
                        expectedChecksum = req.meta.expectedChecksum,
                        expectedMaxCounter = req.meta.expectedMaxCounter,
                        expectedFromCounter = req.meta.expectedFromCounter,
                        expectedToCounter = req.meta.expectedToCounter,
                        expectedWindows = req.meta.expectedWindows,
                    }
                )
                if requestSatisfied then
                    if SF.Debug then
                        SF.Debug:Info("SYNC", "Request %s satisfied: exact author=%s range=%d-%d present",
                            tostring(payload.requestId), tostring(req.meta.author),
                            tonumber(req.meta.fromCounter) or 1, tonumber(req.meta.toCounter) or 0)
                    end
                else
                    if SF.Debug then
                        SF.Debug:Info("SYNC", "Request %s exact-author incomplete: author=%s range=%d-%d still missing locally",
                            tostring(payload.requestId), tostring(req.meta.author),
                            tonumber(req.meta.fromCounter) or 1, tonumber(req.meta.toCounter) or 0)
                    end
                    self:_RetryRequestSoon(req)
                    return
                end
            else
                local contig = self:_ComputeContigCounter(payload.profileId, req.meta.author)
                if contig >= req.meta.toCounter then
                    requestSatisfied = true
                    if SF.Debug then
                        SF.Debug:Info("SYNC", "Request %s satisfied: author=%s contig=%d >= requested=%d",
                            tostring(payload.requestId), tostring(req.meta.author), contig, req.meta.toCounter)
                    end
                else
                    -- Partial response: adjust request to only ask for missing range (Rec 2)
                    -- Update fromCounter to contig+1 to avoid requesting already-merged logs
                    if SF.Debug then
                        SF.Debug:Info("SYNC", "Request %s partial: author=%s contig=%d < requested=%d, adjusting retry range",
                            tostring(payload.requestId), tostring(req.meta.author), contig, req.meta.toCounter)
                    end
                    
                    -- Update request metadata to request only remaining logs
                    req.meta.fromCounter = contig + 1
                    
                    self:_RetryRequestSoon(req)
                    return
                end
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
        if self._DrainAutomaticBisBackfill then
            self:_DrainAutomaticBisBackfill()
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
    if not ok then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting PROFILE_SNAPSHOT from %s: %s", tostring(sender), tostring(err or "unknown"))
        end
        return
    end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.snapshot) ~= "table" then return end

    -- Departed senders must not reach catch-up proof. Snapshots larger than the
    -- proof cache walk local history on every repeat.
    if not self:IsRequesterInGroup(sender) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting PROFILE_SNAPSHOT from %s: not in group", tostring(sender))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring PROFILE_SNAPSHOT from %s: not in group."):format(sender))
        end
        return
    end

    -- Full snapshots remain coordinator/helper-only. Ordinary admins cannot
    -- supply owner, roster, logs, loot mode, Reward Pot, Raid Check, or
    -- equipment state through this path. RC settings use RC_CONFIG_REQ/SET.
    -- Canonical admin revocation outranks a cached helper or in-flight request.
    local snapReq = nil
    if type(payload.requestId) == "string" and self.state.requests then
        snapReq = self.state.requests[payload.requestId]
    end
    local snapDisposition = "untrusted"
    if self._ClassifyPrivilegedResponse then
        local classifyOpts = {
            coordinatorAcceptsAdmins = false,
            expectedKinds = { NEED_PROFILE = true },
        }
        if self._CoordinatorNeedsCatchUp and self:_CoordinatorNeedsCatchUp(sender)
            and self._CatchUpSnapshotProvesGrant
        then
            classifyOpts.catchUpProven = self:_CatchUpSnapshotProvesGrant(sender, payload.snapshot) == true
        end
        snapDisposition = self:_ClassifyPrivilegedResponse(sender, payload.profileId, snapReq, classifyOpts)
    elseif self:IsSenderAuthorized(payload.profileId, sender) and self:IsTrustedDataSender(sender) then
        snapDisposition = "accept"
    elseif not self:IsSenderAuthorized(payload.profileId, sender) then
        snapDisposition = "unauthorized"
    end
    if snapDisposition == "mismatch" then
        self:_NoteResponseKindMismatch(snapReq, sender,
            ("Ignoring PROFILE_SNAPSHOT from %s: response does not match the request."):format(tostring(sender)))
        return
    end
    if snapDisposition == "unproven" then
        self:_NoteUnprovenCatchUp(snapReq, sender,
            ("Ignoring PROFILE_SNAPSHOT from %s: coordinator authority is not established yet."):format(tostring(sender)))
        return
    end
    if snapDisposition == "stale" then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Ignoring stale PROFILE_SNAPSHOT from %s after authorization reconcile",
                tostring(sender))
        end
        return
    end
    if snapDisposition ~= "accept" then
        if snapDisposition == "unauthorized" then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting PROFILE_SNAPSHOT from %s: not an admin of profile", tostring(sender))
            end
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring PROFILE_SNAPSHOT from %s: not an admin of profile."):format(sender))
            end
        else
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting PROFILE_SNAPSHOT from %s: not a trusted sender", tostring(sender))
            end
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring PROFILE_SNAPSHOT from %s: not a trusted sender."):format(sender))
            end
        end
        return
    end

    local senderRole =
        (self.state.coordinator and self:_SamePlayer(sender, self.state.coordinator)) and "coordinator"
        or (self:IsHelper(sender) and "helper" or "unknown")
    if SF.Debug then
        SF.Debug:Info("SYNC", "Accepting PROFILE_SNAPSHOT from %s as %s (profile: %s)",
            tostring(sender), senderRole, tostring(payload.profileId))
        
        -- Debug: log incoming snapshot summary
        local snap = payload.snapshot
        local numMembers = (snap and snap.members and #snap.members) or 0
        local numLogs = (snap and snap.lootLogs and #snap.lootLogs) or 0
        local numAdmins = (snap and snap.adminUsers and #snap.adminUsers) or 0
        local pointName = (snap and snap.pointName) or "Points"
        SF.Debug:Info("SYNC_PROFILE", "Receiving snapshot: %d members, %d logs, %d admins, pointName=%s",
            numMembers, numLogs, numAdmins, pointName)
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
    local replaceExisting = true
    if self:_ProfileAuthorizationKnown() and not self:IsSenderAuthorized(profileId, sender) then
        replaceExisting = false
    end
    local okImport, inserted, importErr = profile:ImportSnapshot(payload.snapshot, {
        allowUnknownEventType = true,
        allowReplaceExisting = replaceExisting,
    })
    if t0 then
        self:_MObserve("sync.merge.profile_snapshot.import_ms", debugprofilestop() - t0)
    end

    if not okImport then
        if SF.PrintWarning then
            SF:PrintWarning(("PROFILE_SNAPSHOT import failed: %s"):format(importErr or "unknown"))
        end
        return
    end

    self.state.rcConfigSeq = tonumber(profile._rcConfigSeq) or 0

    -- Store new profile in canonical map (keyed by profileId)
    if isNew then
        SF.lootHelperDB.profiles[profileId] = profile
        if SF.Debug then
            SF.Debug:Info("SYNC", "Imported new profile: %s (ID: %s)", 
                profile:GetProfileName() or "Unknown", profileId)
        end
    else
        if SF.Debug then
            SF.Debug:Info("SYNC_PROFILE", "Updated existing profile: %s (ID: %s, %d new logs)", 
                profile:GetProfileName() or "Unknown", profileId, inserted or 0)
        end
    end

    -- Metrics: measure rebuild duration
    local t1 = debugprofilestop and debugprofilestop() or nil
    self:RebuildProfile(profileId, "profile_snapshot")
    self:LogSessionPointsSummary(profileId, "profile_snapshot_import")
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
