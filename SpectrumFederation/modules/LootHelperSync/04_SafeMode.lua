local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

-- ============================================================================
-- Helper Functions (Local)
-- ============================================================================

-- Function Normalize a "Name" or "Name-Realm" into "Name-Realm" format.
-- @param name string Player name or "Name-Realm"
-- @return string|nil Normalized "Name-Realm" or nil if invalid
local function NormalizeNameRealm(name)
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name)
    end
    -- Fallback
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then
        local n, r = strsplit("-", name, 2)
        if r then r = r:gsub("%s+", "") end
        return n and r and (n .. "-" .. r) or name
    end
    local realm = GetRealmName()
    if realm then realm = realm:gsub("%s+", "") end
    return realm and (name .. "-" .. realm) or name
end

-- Function Get current group distribution channel ("RAID", "PARTY", or nil).
-- @param none
-- @return string|nil distribution
local function GetGroupDistribution()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- ===========================================================================
-- Local Safe Mode (Session-scoped, local-only)
-- ============================================================================

-- Function Get user sync settings from saved variables.
-- @param none
-- @return table settings
function Sync:_GetUserSyncSettings()
    SF.lootHelperDB = SF.lootHelperDB or { profiles = {}, activeProfileId = nil}
    SF.lootHelperDB.userSettings = SF.lootHelperDB.userSettings or {}
    SF.lootHelperDB.userSettings.sync = SF.lootHelperDB.userSettings.sync or {}
    local s = SF.lootHelperDB.userSettings.sync
    if s.autoLocalSafeModeOnCombat == nil then s.autoLocalSafeModeOnCombat = false end
    return s
end

-- Function Returns whether auto local safe mode on combat is enabled.
-- @param none
-- @return boolean
function Sync:GetAutoLocalSafeModeOnCombatEnabled()
    local s = self:_GetUserSyncSettings()
    return s.autoLocalSafeModeOnCombat == true
end

-- Function Set whether auto local safe mode on combat is enabled.
-- @param enable boolean True to enable, false to disable.
-- @return nil
function Sync:SetAutoLocalSafeModeOnCombatEnabled(enable)
    local s = self:_GetUserSyncSettings()
    s.autoLocalSafeModeOnCombat = (enable == true)
end

-- Function Toggle auto local safe mode on combat enabled state.
-- @param none
-- @return nil
function Sync:ToggleAutoLocalSafeModeOnCombat()
    self:SetAutoLocalSafeModeOnCombatEnabled(not self:GetAutoLocalSafeModeOnCombatEnabled())
end

-- Function Reset Local (session-scoped) safe mode state. Does not touch auto combat safe mode
-- @param reason string|nil Human-readable reason for reset.
-- @return nil
function Sync:_ResetLocalSafeMode(reason)
    local sm = self:_EnsureSafeModeState()
    sm.localEnabled = false
    sm.localSetBy = nil
    sm.localSetAt = nil
    sm.localReason = reason or "reset"

    self:_RecomputeSafeMode("local_reset:" .. tostring(sm.localReason))
end

-- Function Ensure safe mode state structure is initialized.
-- @param none
-- @return table safeModeState
function Sync:_EnsureSafeModeState()
    self.state.safeMode = self.state.safeMode or {}
    local sm = self.state.safeMode

    if sm.sessionEnabled == nil then sm.sessionEnabled = false end
    if sm.sessionRev == nil then sm.sessionRev = 0 end
    if sm.sessionSetBy == nil then sm.sessionSetBy = nil end
    if sm.sessionSetAt == nil then sm.sessionSetAt = nil end
    if sm.sessionReason == nil then sm.sessionReason = nil end

    -- if sm.localEnabled == nil then sm.localEnabled = self:GetLocalSafeModeEnabled() end
    if sm.localEnabled == nil then sm.localEnabled = false end
    if sm.localSetBy == nil then sm.localSetBy = nil end
    if sm.localSetAt == nil then sm.localSetAt = nil end
    if sm.localReason == nil then sm.localReason = nil end

    if sm._effective == nil then
        sm._effective = (sm.sessionEnabled == true) or (sm.localEnabled == true)
    end

    return sm
end

-- Function Returns whether session safe mode is enabled.
-- @param none
-- @return boolean
function Sync:IsLocalSafeModeEnabled()
    local sm = self:_EnsureSafeModeState()
    return sm.localEnabled == true
end

-- Function Returns whether session safe mode is enabled.
-- @param none
-- @return boolean
function Sync:IsSessionSafeModeEnabled()
    local sm = self:_EnsureSafeModeState()
    return sm.sessionEnabled == true
end

-- Function Returns whether safe mode is enabled (either session or local).
-- @param none
-- @return boolean
function Sync:IsSafeModeEnabled()
    local sm = self:_EnsureSafeModeState()
    return (sm.sessionEnabled == true) or (sm.localEnabled == true)
end

-- Function Returns whether bulk transfers are allowed (safe mode disables bulk).
-- @param none
-- @return boolean
function Sync:IsBulkTransferAllowed()
    return not self:IsSafeModeEnabled()
end

-- Function Returns whether local safe mode is enabled.
-- @param none
-- @return boolean
function Sync:GetLocalSafeModeEnabled()
    local sm = self:_EnsureSafeModeState()
    return sm.localEnabled == true
end

-- Function Set whether local safe mode is enabled.
-- @param enabled boolean True to enable, false to disable.
-- @param reason string|nil Human-readable reason for change.
-- @return nil
function Sync:SetLocalSafeModeEnabled(enabled, reason)
    enabled = (enabled == true)
    
    local sm = self:_EnsureSafeModeState()
    if (sm.localEnabled == true) == enabled then
        return
    end

    sm.localEnabled = enabled
    sm.localSetBy = self:_SelfId()
    sm.localSetAt = self:_Now()
    sm.localReason = reason or (enabled and "enabled" or "disabled")

    self:_RecomputeSafeMode("local_set:" .. tostring(sm.localReason))
end

-- Function Toggle local safe mode enabled state.
-- @param reason string|nil Human-readable reason for change.
-- @return nil
function Sync:ToggleLocalSafeMode(reason)
    self:SetLocalSafeModeEnabled(not self:GetLocalSafeModeEnabled(), reason or "toggle")
end

-- Function Returns whether a request kind uses bulk transfers.
-- @param kind string Request kind.
-- @return boolean
function Sync:_RequestKindUsesBulk(kind)
    return (kind == "NEED_PROFILE") -- TODO: Does profile snapshot not?
        or (kind == "NEED_LOGS")
        or (kind == "LOG_REQ")
        or (kind == "ADMIN_LOG_REQ")
end

-- Function Pause all bulk transfer requests.
-- @param reason string|nil Human-readable reason for pausing.
-- @return nil
function Sync:_PauseBulkRequests(reason)
    if type(self.state.requests) ~= "table" then return end
    for _, req in pairs(self.state.requests) do
        if type(req) == "table" and self:_RequestKindUsesBulk(req.kind) then
            req.paused = true
            req.pausedReason = reason
            self:_CancelRequestTimer(req)
        end
    end
end

-- Function Resume all paused requests.
-- @param reason string|nil Human-readable reason for resuming.
-- @return nil
function Sync:_ResumePausedRequests(reason)
    if type(self.state.requests) ~= "table" then return end
    for _, req in pairs(self.state.requests) do
        if type(req) == "table" and req.paused then
            req.paused = nil
            req.pausedReason = nil
            self:_SendRequestAttempt(req)   -- This should also re-arm its timer
        end
    end
end

-- Function Recompute effective safe mode state and apply side-effects.
-- @param reason string|nil Human-readable reason for recompute.
-- @return nil
function Sync:_RecomputeSafeMode(reason)
    local sm = self:_EnsureSafeModeState()
    local effective = (sm.sessionEnabled == true) or (sm.localEnabled == true)
    if sm._effective == effective then return end

    local wasEffective = sm._effective
    sm._effective = effective

    if effective then
        self:_PauseBulkRequests("safe_mode_on:" .. tostring(reason or "unknown"))
        
        -- Metrics: track transition OFF -> ON
        if wasEffective == false then
            self:_MInc("sync.safe_mode.on_count", 1)
            sm._safeModeStartAt = self:_Now()
        end
    else
        self:_ResumePausedRequests("safe_mode_off:" .. tostring(reason or "unknown"))
        
        -- Metrics: track transition ON -> OFF
        if wasEffective == true then
            self:_MInc("sync.safe_mode.off_count", 1)
            
            if type(sm._safeModeStartAt) == "number" then
                local durationSec = self:_Now() - sm._safeModeStartAt
                if durationSec < 0 then durationSec = 0 end
                self:_MObserve("sync.safe_mode.duration_sec", durationSec)
            end
            
            sm._safeModeStartAt = nil
        end
    end

    if SF.Debug then
        SF.Debug:Info("SYNC", "Safe mode now %s (session=%s local=%s reason=%s",
            tostring(effective),
            tostring(sm.sessionEnabled),
            tostring(sm.localEnabled),
            tostring(reason or "unknown")
        )
    end
end

-- Function Reset session safe mode state.
-- @param reason string|nil Human-readable reason for reset.
-- @return nil
function Sync:_ResetSessionSafeMode(reason)
    local sm = self:_EnsureSafeModeState()
    sm.sessionEnabled = false
    sm.sessionRev = 0
    sm.sessionSetBy = nil
    sm.sessionSetAt = nil
    sm.sessionReason = nil

    self:_RecomputeSafeMode("session_reset:" .. tostring(reason or "unknown"))
end

-- Function Apply session safe mode state from incoming payload.
-- @param smPayload table Incoming safe mode payload.
-- @param reason string|nil Human-readable reason for applying.
-- @return nil
function Sync:_ApplySessionSafeModeFromPayload(smPayload, reason)
    if type(smPayload) ~= "table" then return end
    local enabled = (smPayload.enabled == true)
    local incRev = tonumber(smPayload.rev) or 0

    local sm = self:_EnsureSafeModeState()
    local curRev = tonumber(sm.sessionRev) or 0
    local curEnabled = (sm.sessionEnabled == true)

    if incRev < curRev then return end

    if incRev > curRev or enabled ~= curEnabled then
        sm.sessionEnabled = enabled
        sm.sessionRev = incRev
        sm.sessionSetBy = smPayload.setBy
        sm.sessionSetAt = smPayload.setAt
        sm.sessionReason = smPayload.reason

        self:_RecomputeSafeMode("session_apply:" .. tostring(reason or "unknown"))
    end
end

-- Function Build session safe mode payload for outbound messages.
-- @param none
-- @return table payload {enabled, rev, setBy, setAt, reason}
function Sync:_GetSessionSafeModePayload()
    local sm = self:_EnsureSafeModeState()
    return {
        enabled = (sm.sessionEnabled == true),
        rev     = tonumber(sm.sessionRev) or 0,
        setBy   = sm.sessionSetBy,
        setAt   = sm.sessionSetAt,
        reason  = sm.sessionReason,
    }
end

-- Function Ensure that if not in a group, any active session is ended and state reset.
-- @param context string|nil Optional context for logging.
-- @return string|nil distribution channel if in group, nil otherwise
function Sync:_EnforceGroupedSessionActive(context)
    local dist = GetGroupDistribution()
    if dist then return dist end

    local reason = "not_in_group:" .. tostring(context or "unknown")

    -- Safely stop any running timers even if state.active is already false
    self:StopHeartbeatSender(reason)
    self:StopHeartbeatMonitor(reason)

    -- Clear any session identity locally (no broadcast)
    local hasSession =
        (self.state ~= nil) and (
            self.state.active
            or self.state.sessionId
            or self.state.profileId
            or self.state.coordinator
            or self.state.isCoordinator
        )

    if hasSession then
        self:_ResetSessionState(reason)
    end

    return nil
end
