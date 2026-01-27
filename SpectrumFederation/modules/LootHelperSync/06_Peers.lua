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

-- ============================================================================
-- Peer Registry / Roster Helpers
-- ============================================================================

-- Function Generate the next nonce string for messages.
-- @param tag string|nil Optional tag prefix (default: "N")
-- @return string nonce
function Sync:_NextNonce(tag)
    self._nonceCounter = (self._nonceCounter or 0) + 1
    tag = tag or "N"
    return ("%s:%s:%d:%d"):format(tag, self:_SelfId(), self:_Now(), self._nonceCounter)
end

-- Function Get or create a peer record for the given "Name-Realm".
-- @param nameRealm string "Name-Realm"
-- @return table peerRecord
function Sync:GetPeer(nameRealm)
    if type(nameRealm) ~= "string" or nameRealm == "" then return nil end
    self.state.peers = self.state.peers or {}

    local peer = self.state.peers[nameRealm]
    if not peer then
        peer = {
            name = nameRealm,
            inGroup = false,
            online = nil,
            lastSeen = 0,
            proto = nil,
            supportedMin = nil,
            supportedMax = nil,
            addonVersion = nil,
            isAdmin = nil,
            syncState = "UNKNOWN",
            syncStateAt = 0,
            syncStateReason = nil,
        }
        self.state.peers[nameRealm] = peer
    end
    return peer
end

-- Function Update peer record's lastSeen and optional fields.
-- @param nameRealm string "Name-Realm"
-- @param fields table|nil Optional fields to update in peer record
-- @return nil
function Sync:TouchPeer(nameRealm, fields)
    local peer = self:GetPeer(nameRealm)
    if not peer then return end

    peer.lastSeen = self:_Now()
    if type(fields) == "table" then
        for k, v in pairs(fields) do
            peer[k] = v
        end
    end

    -- Advance from UNKNOWN or nil to SEEN, but don't overwrite meaningful states
    if not peer.syncState or peer.syncState == "UNKNOWN" then
        peer.syncState = "SEEN"
        peer.syncStateAt = self:_Now()
    end
end

function Sync:SetPeerSyncState(nameRealm, state, reason)
    local peer = self:GetPeer(nameRealm)
    if not peer then return end

    if peer.syncState ~= state then
        peer.syncState = state
        peer.syncStateAt = self:_Now()
        peer.syncStateReason = reason
    end
end

-- Function Update peer records from current group/raid roster.
-- @param none
-- @return nil
function Sync:UpdatePeersFromRoster()
    self.state.peers = self.state.peers or {}

    -- mark everyone "not inGroup" first; we'll re-mark those we find
    for _, peer in pairs(self.state.peers) do
        peer.inGroup = false
        peer.online = nil
    end

    if IsInRaid() then
        local n = GetNumGroupMembers() or 0
        for i = 1, n do
            local name, rank, subgroup, level, class, fileName, zone, online, isDead, role = GetRaidRosterInfo(i)
            local full = NormalizeNameRealm(name)
            if full then
                local peer = self:GetPeer(full)
                peer.inGroup = true
                peer.online = online
                peer.rank = rank
                peer.subgroup = subgroup
                peer.role = role
            end
        end
    elseif IsInGroup() then
        local function touchUnit(unit)
            local n, r = UnitFullName(unit)
            if not n then return end
            local full = NormalizeNameRealm(r and (n .. "-" .. r) or n)
            if full then
                local peer = self:GetPeer(full)
                peer.inGroup = true
                peer.online = UnitIsConnected(unit)
                peer.role = UnitGroupRolesAssigned(unit)
            end
        end

        touchUnit("player")
        for i = 1, (GetNumSubgroupMembers() or 0) do
            touchUnit("party" .. i)
        end
    end
end

-- Function Mark all in-group peers as having announced for the given sessionId.
-- @param sessionId string Session id
-- @return nil
function Sync:_MarkRosterAnnounced(sessionId)
    if type(sessionId) ~= "string" or sessionId == "" then return end
    self:UpdatePeersFromRoster()

    for _, peer in pairs(self.state.peers or {}) do
        if peer and peer.inGroup then
            peer._lastSessionAnnounced = sessionId
        end
    end
end

-- Function Get the current addon version string.
-- @param none
-- @return string version
function Sync:_GetAddonVersion()
    if SF.GetAddonVersion then
        return SF:GetAddonVersion()
    end
    return "unknown"
end
