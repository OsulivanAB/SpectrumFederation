local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


-- Function Route an incoming CONTROL message to the appropriate handler.
-- @param sender string "Name-Realm" of sender
-- @param msgType string Message type (from Sync.MSG)
-- @param payload table Decoded message payload
-- @param distribution string Message distribution channel ("WHISPER", "RAID", etc.)
-- @return nil
function Sync:OnControlMessage(sender, msgType, payload, distribution)
    -- Update peer registry from "any message received"
    -- Comm already validated protocol and decoded payload
    self:TouchPeer(sender, { proto = (SF.SyncProtocol and SF.SyncProtocol.PROTO_CURRENT) or nil })

    do
        if self:MetricsEnabled() then
            local prefixStr = self.PREFIX and self.PREFIX.CONTROL or "CONTROL"
            self:_MInc("sync.msg.recv.total", 1)
            self:_MInc("sync.msg.recv.prefixKey.CONTROL", 1)
            self:_MInc("sync.msg.recv.prefix." .. tostring(prefixStr), 1)
            if type(msgType) == "string" and msgType ~= "" then
                self:_MInc("sync.msg.recv.type." .. msgType, 1)
            end
            if type(distribution) == "string" and distribution ~= "" then
                self:_MInc("sync.msg.recv.dist." .. distribution, 1)
            end
        end
    end

    if self.state and self.state.active and self.state.coordinator and self:_SamePlayer(sender, self.state.coordinator) then
        self.state.heartbeat = self.state.heartbeat or {}
        self.state.heartbeat.lastCoordMessageAt = self:_Now()
    end

    local t0 = debugprofilestop and debugprofilestop() or nil

    local r1, r2
    local function dispatch()
        if msgType == self.MSG.ADMIN_SYNC then return self:HandleAdminSync(sender, payload) end
        if msgType == self.MSG.ADMIN_STATUS then return self:HandleAdminStatus(sender, payload) end
        if msgType == self.MSG.LOG_REQ then return self:HandleLogRequest(sender, payload) end

        if msgType == self.MSG.SES_START then return self:HandleSessionStart(sender, payload) end
        if msgType == self.MSG.HAVE_PROFILE then return self:HandleHaveProfile(sender, payload) end
        if msgType == self.MSG.NEED_PROFILE then return self:HandleNeedProfile(sender, payload) end
        if msgType == self.MSG.NEED_LOGS then return self:HandleNeedLogs(sender, payload) end

        if msgType == self.MSG.SES_REANNOUNCE then return self:HandleSessionReannounce(sender, payload) end
        if msgType == self.MSG.COORD_TAKEOVER then return self:HandleCoordinatorTakeover(sender, payload) end
        if msgType == self.MSG.SES_END then return self:HandleSessionEnd(sender, payload) end
        if msgType == self.MSG.SES_HEARTBEAT then return self:HandleSessionHeartbeat(sender, payload) end

        if msgType == self.MSG.SAFE_MODE_REQ then return self:HandleSafeModeRequest(sender, payload) end
        if msgType == self.MSG.SAFE_MODE_SET then return self:HandleSafeModeSet(sender, payload) end
        
        if SF.Debug then
            SF.Debug:Warn("SYNC", "Unknown CONTROL message type (msgType=%s, sender=%s, dist=%s)",
                tostring(msgType), tostring(sender), tostring(distribution))
        end
        return nil
    end

    r1, r2 = dispatch()

    if t0 then
        local ms = debugprofilestop() - t0
        self:_MetricsObserveHandlerMs("CONTROL", msgType, ms)
    end

    return r1, r2
end

-- Function Route an incoming BULK message to the appropriate handler.
-- @param sender string "Name-Realm" of sender
-- @param msgType string Message type (from Sync.MSG)
-- @param payload table Decoded message payload
-- @param distribution string Message distribution channel ("WHISPER", "RAID", etc.)
-- @return nil
function Sync:OnBulkMessage(sender, msgType, payload, distribution)
    self:TouchPeer(sender, { proto = (SF.SyncProtocol and SF.SyncProtocol.PROTO_CURRENT) or nil })

    do
        if self:MetricsEnabled() then
            local prefixStr = self.PREFIX and self.PREFIX.BULK or "BULK"
            self:_MInc("sync.msg.recv.total", 1)
            self:_MInc("sync.msg.recv.prefixKey.BULK", 1)
            self:_MInc("sync.msg.recv.prefix." .. tostring(prefixStr), 1)
            if type(msgType) == "string" and msgType ~= "" then
                self:_MInc("sync.msg.recv.type." .. msgType, 1)
            end
            if type(distribution) == "string" and distribution ~= "" then
                self:_MInc("sync.msg.recv.dist." .. distribution, 1)
            end
        end
    end

    if self.state and self.state.active and self.state.coordinator and self:_SamePlayer(sender, self.state.coordinator) then
        self.state.heartbeat = self.state.heartbeat or {}
        self.state.heartbeat.lastCoordMessageAt = self:_Now()
    end

    if self:IsSafeModeEnabled() then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Safe mode: dropping BULK %s from %s", tostring(msgType), tostring(sender))
        end
        self:_MInc("sync.msg.drop.safe_mode.total", 1)
        self:_MInc("sync.msg.drop.safe_mode.type." .. tostring(msgType or "UNKNOWN"), 1)
        self:_MInc("sync.msg.drop.safe_mode.prefixKey.BULK", 1)
        return
    end

    local t0 = debugprofilestop and debugprofilestop() or nil

    local r1, r2
    local function dispatch()
        if msgType == self.MSG.AUTH_LOGS then return self:HandleAuthLogs(sender, payload) end
        if msgType == self.MSG.PROFILE_SNAPSHOT then return self:HandleProfileSnapshot(sender, payload) end
        if msgType == self.MSG.NEW_LOG then return self:HandleNewLog(sender, payload) end
        
        if SF.Debug then
            SF.Debug:Warn("SYNC", "Unknown BULK message type (msgType=%s, sender=%s, dist=%s)",
                tostring(msgType), tostring(sender), tostring(distribution))
        end
        return nil
    end

    r1, r2 = dispatch()

    if t0 then
        local ms = debugprofilestop() - t0
        self:_MetricsObserveHandlerMs("BULK", msgType, ms)
    end

    return r1, r2
end

