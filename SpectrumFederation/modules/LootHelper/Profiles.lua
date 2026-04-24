-- Grab the namespace
local addonName, SF = ...

-- Note: Will need a reset profile, delete profile, create profile, rename profile, manage admins, get/set for both safe modes for UI to use

-- ============================================================================
-- Loot Profile
-- ============================================================================

local LootProfile = {}
LootProfile.__index = LootProfile

local PROFILE_META_VERSION = 1
local PROFILE_SNAPSHOT_VERSION = 1

local function CopyTableShallow(src)
	if type(src) ~= "table" then return {} end
	local dst = {}
	for k, v in pairs(src) do
		dst[k] = v
	end
	return dst
end

local RAID_CHECK_SLOT_DEFAULTS = {
	head = true,
	neck = true,
	shoulders = true,
	back = true,
	chest = true,
	wrist = true,
	hands = true,
	belt = true,
	legs = true,
	boots = true,
	rings = true,
	trinkets = true,
	weapon = true,
	offHand = true,
}

local RAID_CHECK_DEFAULTS = {
	enableWhispersPreRaid = false,
	enableWhispersRaid = false,
    checkGemsInSockets = true,
    requireMetaGem = false,
	slots = RAID_CHECK_SLOT_DEFAULTS,
}

local function CopyRaidCheckDefaults()
	return {
		enableWhispersPreRaid = RAID_CHECK_DEFAULTS.enableWhispersPreRaid,
		enableWhispersRaid = RAID_CHECK_DEFAULTS.enableWhispersRaid,
        checkGemsInSockets = RAID_CHECK_DEFAULTS.checkGemsInSockets,
        requireMetaGem = RAID_CHECK_DEFAULTS.requireMetaGem,
		slots = CopyTableShallow(RAID_CHECK_DEFAULTS.slots),
	}
end

local function NormalizeSlotKey(key)
	if type(key) ~= "string" then return nil end
	if key == "mainHand" then
		return "weapon"
	end
	return key
end

function LootProfile:_EnsureRaidCheckConfig()
	if type(self._raidCheckConfig) ~= "table" then
		self._raidCheckConfig = CopyRaidCheckDefaults()
	end

	local cfg = self._raidCheckConfig

	if type(cfg.slots) ~= "table" then
		cfg.slots = CopyTableShallow(RAID_CHECK_DEFAULTS.slots)
	end

	if cfg.slots.mainHand ~= nil then
		if cfg.slots.weapon == nil then
			cfg.slots.weapon = not not cfg.slots.mainHand
		end
		cfg.slots.mainHand = nil
	end

	for slotKey, defaultEnabled in pairs(RAID_CHECK_SLOT_DEFAULTS) do
		if cfg.slots[slotKey] == nil then
			cfg.slots[slotKey] = defaultEnabled
		end
	end

	cfg.enableWhispersPreRaid = cfg.enableWhispersPreRaid and true or false
	cfg.enableWhispersRaid = cfg.enableWhispersRaid and true or false
    cfg.checkGemsInSockets = cfg.checkGemsInSockets ~= false
	cfg.requireMetaGem = cfg.requireMetaGem and true or false
end

function LootProfile:_EnsureRaidCheckEquipmentSnapshots()
	if type(self._raidCheckEquipmentSnapshots) ~= "table" then
		self._raidCheckEquipmentSnapshots = {}
	end
end

local function CopyArray(arr)
    local out = {}
    for i = 1, #(arr or {}) do out[i] = arr[i] end
    return out
end

local function CopyRaidCheckEquipmentSlots(slotsByInventory)
	local copy = {}
	for inventorySlot, slotData in pairs(slotsByInventory or {}) do
		if type(slotData) == "table" then
			copy[inventorySlot] = {
				link = type(slotData.link) == "string" and slotData.link or nil,
				hasItem = slotData.hasItem and true or false,
				texture = slotData.texture,
				itemLevel = tonumber(slotData.itemLevel) or nil,
			}
		end
	end
	return copy
end

local function CopyRaidCheckEquipmentSnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return nil
	end

	return {
		capturedAt = tonumber(snapshot.capturedAt) or nil,
		averageItemLevel = tonumber(snapshot.averageItemLevel) or nil,
		slotsByInventory = CopyRaidCheckEquipmentSlots(snapshot.slotsByInventory),
	}
end

-- Local helper functions for member ID normalization and comparison
-- @param string id Member full identifier "Name-Realm"
-- @return string normalizedId
local function NormalizeMemberId(id)
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(id) or id
    end
    return id
end

-- Local helper function to compare two member IDs
-- @param string a Member full identifier "Name-Realm"
-- @param string b Member full identifier "Name-Realm"
-- @return boolean equal
local function SameMember(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

-- Local helper: generate a short, very-low-collision profileId
-- We use multiple random 31-bit chunks + server time.
-- math.random is backed by WoW's securerandom RNG in modern clients.
-- @return string profileId
local function GenerateProfileId()
    local time = GetServerTime() or time()
    local ran1 = math.random(0, 0x7fffffff)
    local ran2 = math.random(0, 0x7fffffff)
    -- Format: "p_" prefix + three 8-digit zero-padded hex values (time + 2 random numbers)
    return ("p_%08x%08x%08x"):format(time, ran1, ran2)
end

-- ========================================================================
-- Identity + Counters (FOUNDATION)
-- ========================================================================

-- Function: Return stable profileId for this profile
-- @param none
-- @return string profileId
function LootProfile:GetProfileId()
    return self._profileId
end

-- Function: Set profileId if it is currently nil (useful for imports/migrations)
-- @param string profileId Stable profile identifier
-- @return nil
function LootProfile:SetProfileIdIfNil(profileId)
    if self._profileId ~= nil then
        return  
    end

    if type(profileId) ~= "string" or profileId == "" then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "SetProfileIdIfNil called with invalid profileId:", profileId)
        end
        return
    end

    self._profileId = profileId
end

-- Function: allocate and return the next counter for a given author (used when creating new logs locally).
-- IMPORTANT: This is per-profile, per-author. That's what prevents multi-writer collissions.
-- @param author string "Name-Realm" of author
-- @return number nextCounter
function LootProfile:AllocateNextCounter(author)
    if type(author) ~= "string" or author == "" then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "AllocateNextCounter called with invalid author:", author)
        end
        return nil
    end

    self._authorCounters = self._authorCounters or {}
    local nextCounter = (self._authorCounters[author] or 0) + 1
    self._authorCounters[author] = nextCounter
    return nextCounter
end

-- ========================================================================
-- Constructor
-- ========================================================================

-- Constructor for creating a new loot profile
-- @param profileName string Human-readable name for this profile
-- @return LootProfile instance or nil if failed
function LootProfile.new(profileName)
    -- Validate profile Name
    if type(profileName) ~= "string" or profileName == "" then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Invalid profile name provided: %s", tostring(profileName))
        end
        return nil
    end

    local instance = setmetatable({}, LootProfile)

    instance._profileName = profileName
    instance._profileId = GenerateProfileId()
    instance._author = SF:GetPlayerFullIdentifier() -- "Name-Realm" of creator
    instance._owner = instance._author -- Initially owned by creator
    instance._lootLogs = {}
    instance._members = {}
    instance._adminUsers = {}
    instance._activeProfile = false
    instance._authorCounters = {}
    instance._pointName = "Points"
    instance._raidWideSafeMode = false
    instance._raidWideSafeModeOnCombat = false
    instance._raidCheckConfig = CopyRaidCheckDefaults()
    instance._raidCheckEquipmentSnapshots = {}
    -- Create member instance for author
    local class = SF:GetPlayerClass()
    local adminRole = (SF.MemberRoles and SF.MemberRoles.ADMIN) or "admin"
    local authorMember = SF.Member.new(instance._author, adminRole, class or "UNKNOWN")
    if not authorMember then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Failed to create member instance for author:", instance._author)
        end
        return nil
    end

    table.insert(instance._members, authorMember)
    table.insert(instance._adminUsers, instance._author)


    -- Create Log Entry for profile creation
    local logEventType = SF.LootLogEventTypes.PROFILE_CREATION
    local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
    if not logEventData then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Failed to get log event data template for profile creation")
        end
        return nil
    end

    -- Put profileId into the creation log so profile identity is log-backed
    logEventData.profileId = instance._profileId

    local creationCounter = instance:AllocateNextCounter(instance._author)
    local logEntry = SF.LootLog.new(logEventType, logEventData, {
        author = instance._author,
        counter = creationCounter,
        skipPermission = true, -- creation is special; no activeProfile yet
    })

    if not logEntry then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Failed to create log entry for profile creation")
        end
        return nil
    end

    table.insert(instance._lootLogs, logEntry)

    instance:_EnsureOwnerIsAdmin()

    return instance
end

-- Function Compute max counter per author found in this profile's logs.
-- This is the sync summary: { [author] = maxCounterSeen }
-- @param none
-- @return table authorMaxCounters
function LootProfile:ComputeAuthorMax()
    local authorMax = {}

    for _, log in ipairs(self._lootLogs or {}) do
        local author = log.GetAuthor and log:GetAuthor() or log._author
        local counter = log.GetCounter and log:GetCounter() or log._counter

        if type(author) == "string" and type(counter) == "number" then
            local prev = authorMax[author] or 0
            if counter > prev then
                authorMax[author] = counter
            end
        end
    end

    return authorMax
end

-- Function Compute number of logs per author (debug only; not used for sync decisions)
-- @param none
-- @return table counts { [author] = numberOfLogs }
function LootProfile:ComputeAuthorCounts()
    local counts = {}

    for _, log in ipairs(self._lootLogs or {}) do
        local author = log.GetAuthor and log:GetAuthor() or log._author

        if type(author) == "string" then
            counts[author] = (counts[author] or 0) + 1
        end
    end

    return counts
end

-- Function Rebuild log index and refresh max counters from the current log list
-- @param none
-- @return nil
function LootProfile:RebuildLogIndex()
    self._logIndex = {}
    self._authorCounters = self._authorCounters or {}

    for _, log in ipairs(self._lootLogs or {}) do
        local id = log.GetID and log:GetID() or log._id
        if type(id) == "string" and id ~= "" then
            self._logIndex[id] = true
        end

        local author = log.GetAuthor and log:GetAuthor() or log._author
        local counter = log.GetCounter and log:GetCounter() or log._counter
        if type(author) == "string" and type(counter) == "number" then
            local prev = self._authorCounters[author] or 0
            if counter > prev then
                self._authorCounters[author] = counter
            end
        end
    end
end

-- Function Compare two logs for stable deterministic ordering
-- Primary key: timestamp
-- Tie-breaks: author, counter, id
-- @param a LootLog instance A
-- @param b LootLog instance B
-- @return boolean true if a < b
function LootProfile:_CompareLogs(a, b)
    local aTime = a.GetTimestamp and a:GetTimestamp() or a._timestamp
    local bTime = b.GetTimestamp and b:GetTimestamp() or b._timestamp
    if aTime ~= bTime then
        return aTime < bTime
    end

    local aAuthor = a.GetAuthor and a:GetAuthor() or a._author
    local bAuthor = b.GetAuthor and b:GetAuthor() or b._author
    if aAuthor ~= bAuthor then
        return aAuthor < bAuthor
    end

    local aCounter = a.GetCounter and a:GetCounter() or a._counter
    local bCounter = b.GetCounter and b:GetCounter() or b._counter
    if aCounter ~= bCounter then
        return aCounter < bCounter
    end

    local aId = a.GetID and a:GetID() or a._id
    local bId = b.GetID and b:GetID() or b._id
    return aId < bId
end

-- ========================================================================
-- Getter Methods
-- ========================================================================

-- Function to get creation time by finding the PROFILE_CREATION log
-- @return number Creation timestamp or nil if not found
function LootProfile:GetCreationTime()
    for _, logEntry in ipairs(self._lootLogs or {}) do
        if logEntry:GetEventType() == SF.LootLogEventTypes.PROFILE_CREATION then
            return logEntry:GetTimestamp()
        end
    end
    return nil
end

-- Function to get the profile's human-readable name
-- @return string profileName
function LootProfile:GetProfileName()
    return self._profileName
end

-- Function to check if this profile is the active profile
-- @return boolean isActive
function LootProfile:IsActive()
    return self._activeProfile
end

-- Function to get the profile's author ("Name-Realm")
-- @return string author
function LootProfile:GetAuthor()
    return self._author
end

-- Function to get the profile's owner ("Name-Realm")
-- @return string owner
function LootProfile:GetOwnerId()
    return self._owner
end

-- Function to check if a given memberId is the owner of this profile
-- @param memberId (string) - Member full identifier "Name-Realm"
-- @return (boolean) - True if memberId is the owner, false otherwise
function LootProfile:IsOwner(memberId)
    if type(memberId) ~= "string" or memberId == "" then return false end
    return SameMember(NormalizeMemberId(memberId), self._owner)
end

-- Function to get the list of members in this profile
-- @return table members List of LootProfileMember instances
function LootProfile:GetMemberList()
    return self._members
end

-- Function to get the list of loot logs in this profile
-- @return table lootLogs List of LootLog instances
function LootProfile:GetLootLogs()
    return self._lootLogs
end

-- Function to get the list of admin users in this profile
-- @return table adminUsers List of "Name-Realm" strings
function LootProfile:GetAdminUsers()
    return self._adminUsers
end

-- Function to get the last modified time of the profile by checking all log entries
-- @return number latest timestamp or nil if no logs
function LootProfile:GetLastModifiedTime()
    local latestTime = nil
    for _, logEntry in ipairs(self._lootLogs or {}) do
        local ts = logEntry:GetTimestamp()
        if not latestTime or ts > latestTime then
            latestTime = ts
        end
    end
    return latestTime
end

-- Function to check if the current user is an admin of this profile
-- @return boolean isAdmin
function LootProfile:IsCurrentUserAdmin()
    local currentUser = SF:GetPlayerFullIdentifier()
    if not currentUser then return false end
    
    for _, admin in ipairs(self._adminUsers) do
        -- Use NameUtil for case-insensitive comparison if available
        if SF.NameUtil and SF.NameUtil.SamePlayer then
            if SF.NameUtil.SamePlayer(admin, currentUser) then
                return true
            end
        elseif admin == currentUser then
            return true
        end
    end
    return false
end

-- Function to get the point name for this profile
-- @return string pointName
function LootProfile:GetPointName()
    local name = self._pointName
    if name == nil or name == "" then
        return "Points"
    end
    return name
end

-- Function to get the raid-wide safe mode setting
-- @return boolean raidWideSafeMode
function LootProfile:GetRaidWideSafeMode()
	return self._raidWideSafeMode and true or false
end

-- Function to get the raid-wide safe mode on combat setting
-- @return boolean raidWideSafeModeOnCombat
function LootProfile:GetRaidWideSafeModeOnCombat()
	return self._raidWideSafeModeOnCombat and true or false
end

-- Function get Raid Check configuration (copy)
-- @return table raidCheckConfig
function LootProfile:GetRaidCheckConfig()
	self:_EnsureRaidCheckConfig()

	return {
		enableWhispersPreRaid = self._raidCheckConfig.enableWhispersPreRaid and true or false,
		enableWhispersRaid = self._raidCheckConfig.enableWhispersRaid and true or false,
        checkGemsInSockets = self._raidCheckConfig.checkGemsInSockets ~= false,
        requireMetaGem = self._raidCheckConfig.requireMetaGem and true or false,
		slots = CopyTableShallow(self._raidCheckConfig.slots),
	}
end

function LootProfile:GetRaidCheckEquipmentSnapshot(memberId)
	self:_EnsureRaidCheckEquipmentSnapshots()
	if type(memberId) ~= "string" or memberId == "" then
		return nil
	end

	memberId = NormalizeMemberId(memberId)
	if not self:GetMemberByID(memberId) then
		return nil
	end
	local snapshot = self._raidCheckEquipmentSnapshots[memberId]
	if type(snapshot) ~= "table" then
		return nil
	end

	snapshot.preparedSlotsByConfig = snapshot.preparedSlotsByConfig or {}
	return snapshot
end

function LootProfile:GetRaidCheckEquipmentSnapshotIds()
	self:_EnsureRaidCheckEquipmentSnapshots()
	local ids = {}
	for memberId, snapshot in pairs(self._raidCheckEquipmentSnapshots) do
		if type(memberId) == "string" and memberId ~= "" and type(snapshot) == "table" and self:GetMemberByID(memberId) then
			table.insert(ids, memberId)
		end
	end
	table.sort(ids)
	return ids
end

function LootProfile:SetRaidCheckEquipmentSnapshot(memberId, snapshot)
	self:_EnsureRaidCheckEquipmentSnapshots()
	if type(memberId) ~= "string" or memberId == "" or type(snapshot) ~= "table" then
		return false
	end

	memberId = NormalizeMemberId(memberId)
	if not self:GetMemberByID(memberId) then
		return false
	end

	local snapshotCopy = CopyRaidCheckEquipmentSnapshot(snapshot)
	if not snapshotCopy then
		return false
	end

	snapshotCopy.preparedSlotsByConfig = {}
	self._raidCheckEquipmentSnapshots[memberId] = snapshotCopy
	return true
end

-- Function check if a Raid Check slot is enabled
-- @param string slotKey
-- @return boolean enabled
function LootProfile:IsRaidCheckSlotEnabled(slotKey)
	self:_EnsureRaidCheckConfig()
	slotKey = NormalizeSlotKey(slotKey)
	if not slotKey then return false end
	return self._raidCheckConfig.slots[slotKey] and true or false
end

-- Function toggle Raid Check slot expectation
-- @param string slotKey
-- @param boolean enabled
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidCheckSlotEnabled(slotKey, enabled)
	self:_EnsureRaidCheckConfig()
	slotKey = NormalizeSlotKey(slotKey)
	if not slotKey then
		return false, "Invalid slot key."
	end

	if self._raidCheckConfig.slots[slotKey] == nil then
		return false, "Unknown slot key."
	end

	if not self:IsCurrentUserAdmin() then
		return false, "You must be an admin to change Raid Check settings."
	end

	self._raidCheckConfig.slots[slotKey] = enabled and true or false
	return true, nil
end

-- Function toggle Raid Check whisper settings
-- @param string mode "pre" or "raid"
-- @param boolean enabled
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidCheckWhispers(mode, enabled)
	self:_EnsureRaidCheckConfig()
	if not self:IsCurrentUserAdmin() then
		return false, "You must be an admin to change Raid Check settings."
	end

	if mode == "pre" then
		self._raidCheckConfig.enableWhispersPreRaid = enabled and true or false
	elseif mode == "raid" then
		self._raidCheckConfig.enableWhispersRaid = enabled and true or false
	else
		return false, "Invalid whisper mode."
	end

	return true, nil
end

-- Function toggle gem socket validation during Raid Check
-- @param boolean enabled
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidCheckGemSocketsEnabled(enabled)
    self:_EnsureRaidCheckConfig()
    if not self:IsCurrentUserAdmin() then
        return false, "You must be an admin to change Raid Check settings."
    end

    self._raidCheckConfig.checkGemsInSockets = enabled and true or false
    return true, nil
end

-- Function toggle meta gem requirement during Raid Check
-- @param boolean enabled
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidCheckMetaGemRequired(enabled)
    self:_EnsureRaidCheckConfig()
    if not self:IsCurrentUserAdmin() then
        return false, "You must be an admin to change Raid Check settings."
    end

    self._raidCheckConfig.requireMetaGem = enabled and true or false
    return true, nil
end

-- Function Get list of admin member IDs
-- @return table adminMemberIds List of "Name-Realm" strings
function LootProfile:getAdminMemberIds()
    return CopyArray(self._adminUsers or {})
end

-- Function Get list of all member IDs
-- @return table memberIds List of "Name-Realm" strings
function LootProfile:getMemberIds()
    local out = {}
    for _, m in ipairs(self._members or {}) do
        local id = m.GetFullIdentifier and m:GetFullIdentifier() or m.identifier
        if type(id) == "string" and id ~= "" then
            table.insert(out, id)
        end
    end
    table.sort(out)
    return out
end

function LootProfile:GetMemberIds()
	if self.getMemberIds then
		return self:getMemberIds()
	end
	return {}
end

-- Function Get member by their ID
-- @param string id "Name-Realm" of member
-- @return LootProfileMember|nil member Instance or nil if not found
function LootProfile:getMemberByID(id)
    if type(id) ~= "string" or id == "" then return nil end
    id = NormalizeMemberId(id)

    for _, m in ipairs(self._members or {}) do
        local mid = m.GetFullIdentifier and m:GetFullIdentifier() or m.identifier
        if type(mid) == "string" and mid ~= "" and SameMember(id, mid) then
            return m
        end
    end
    return nil
end

-- Alias for capitalized method name used by some callers
function LootProfile:GetMemberByID(id)
    if self.getMemberByID then
        return self:getMemberByID(id)
    end
    return nil
end

-- ========================================================================
-- Setter Methods
-- ========================================================================

-- Function to set this profile as active or inactive
-- @param boolean isActive
-- @return nil
function LootProfile:SetActive(isActive)
    self._activeProfile = isActive
end

-- Function to set a new profile name
-- @param string newName New human-readable name for this profile
-- @return nil
function LootProfile:SetProfileName(newName)
    if type(newName) == "string" and newName ~= "" then
        local oldName = self._profileName
        self._profileName = newName
        
        -- Create log entry for profile name change
        if SF.LootLog and oldName and oldName ~= newName then
            local eventType = SF.LootLogEventTypes.PROFILE_NAME_CHANGE
            local eventData = SF.LootLog.GetEventDataTemplate(eventType)
            eventData.oldName = oldName
            eventData.newName = newName
            
            local logEntry = SF.LootLog.new(eventType, eventData)
            if logEntry and self.AddLootLog then
                self:AddLootLog(logEntry)
            end
        end
    else
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to set invalid profile name: %s", tostring(newName))
        end
    end
end

-- Function to set a new owner for this profile
-- @param string newOwner "Name-Realm" of new owner
-- @return nil
function LootProfile:SetOwner(newOwner)
    -- Normalize owner name using NameUtil
    local normalized = nil
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        normalized = SF.NameUtil.NormalizeNameRealm(newOwner)
    elseif type(newOwner) == "string" and newOwner:match("^[^%-]+%-[^%-]+$") then
        normalized = newOwner
    end
    
    if normalized then
        self._owner = normalized
    else
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to set invalid owner: %s", tostring(newOwner))
        end
    end
end

-- Function to add a loot log entry to this profile
-- @param LootLog lootLog Instance of LootLog to add
-- @return boolean success
function LootProfile:AddLootLog(lootLog)
    local ok, err = self:_InsertLog(lootLog, { requireAdmin = true })
    if ok then
        -- If Sync is loaded, ask it to broadcast this log.
        -- Sync will no-op unless there is an active session AND the profileId matches.
        if SF
            and SF.LootHelperSync
            and SF.LootHelperSync.BroadcastNewLog
            and self.GetProfileId
            and lootLog
            and lootLog.ToTable
        then
            local broadcastOk, broadcastErr = SF.LootHelperSync:BroadcastNewLog(self:GetProfileId(), lootLog:ToTable())
            if not broadcastOk then
                if SF.PrintWarning then
                    SF:PrintWarning("Change saved locally but not synced to raid: " .. tostring(broadcastErr or "unknown error"))
                end
            end
        end
    end
    return ok, err
end

-- Function Insert a log entry with dedupe + stable ordering
-- opts.requireAdmin: if true, enforce current user admin check (local writes).
-- @param lootLog LootLog instance to insert
-- @param opts table|nil optional:
--     opts.requireAdmin boolean enforce admin check (default: true)
-- @return boolean inserted True if new, false if duplicate/invalid
function LootProfile:_InsertLog(lootLog, opts)
    opts = opts or {}

    if getmetatable(lootLog) ~= SF.LootLog then
        if SF.Debug then
            SF.Debug("LootProfile", "_InsertLog: Invalid LootLog instance provided:", tostring(lootLog))
        end
        return false
    end

    if opts.requireAdmin and not self:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug("LootProfile", "_InsertLog: Current user is not an admin; cannot add loot log entries")
        end
        return false
    end

    self._lootLogs = self._lootLogs or {}
    self._logIndex = self._logIndex or {}
    self._authorCounters = self._authorCounters or {}

    local id = lootLog:GetID()
    if type(id) ~= "string" or id == "" then
        return false
    end

    -- Dedupe
    if self._logIndex[id] then
        return false
    end

    self._logIndex[id] = true
    table.insert(self._lootLogs, lootLog)
    
    -- Keep authorCounters synced to max seen
    local author = lootLog:GetAuthor()
    local counter = lootLog:GetCounter()
    if type(author) == "string" and type(counter) == "number" then
        local prev = self._authorCounters[author] or 0
        if counter > prev then
            self._authorCounters[author] = counter
        end
    end

    table.sort(self._lootLogs, function(a, b)
        return self:_CompareLogs(a, b)
    end)

    return true
end

-- Function to add a member to this profile
-- @param Member member Instance of Member to add
-- @return boolean success
function LootProfile:AddMember(member)
    local mt = getmetatable(member)
    if mt == SF.Member or mt == SF.LootProfileMember then
        self._members = self._members or {}
        table.insert(self._members, member)
        return true
    else
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to add invalid LootProfileMember instance: %s", tostring(member))
        end
        return false
    end
end

-- Function to add an admin user to this profile
-- @param Member member Instance of Member to add as admin
-- @return boolean success
function LootProfile:AddAdminUser(member)
    local mt = getmetatable(member)
    if mt == SF.Member or mt == SF.LootProfileMember then
        local id = member.GetFullIdentifier and member:GetFullIdentifier() or member.identifier
        return self:AddAdminMemberId(id)
    else
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to add invalid LootProfileMember instance as admin: %s", tostring(member))
        end
        return false
    end
end

-- Function to set the point name for this profile
-- @param string name New point name
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetPointName(name)
	if not self:IsCurrentUserAdmin() then
		return false, "You must be an admin to change Point Name."
	end
	name = tostring(name or ""):match("^%s*(.-)%s*$")
	if name == "" then
		return false, "Point Name cannot be empty."
	end
	
	local oldName = self._pointName or "Points"
	self._pointName = name
	
	-- Create log entry for point name change
	if SF.LootLog then
		local eventType = SF.LootLogEventTypes.POINT_NAME_CHANGE
		local eventData = SF.LootLog.GetEventDataTemplate(eventType)
		eventData.oldName = oldName
		eventData.newName = name
		
		local logEntry = SF.LootLog.new(eventType, eventData)
		if logEntry and self.AddLootLog then
			self:AddLootLog(logEntry)
		end
	end
	
	return true
end

-- Function to set the raid-wide safe mode setting
-- @param boolean v New raid-wide safe mode value
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidWideSafeMode(v)
	if not self:IsCurrentUserAdmin() then
		return false, "You must be an admin to change Raid-Wide Safemode."
	end
	
	local enabled = v and true or false
	self._raidWideSafeMode = enabled
	
	-- Create log entry for safemode change
	if SF.LootLog then
		local eventType = SF.LootLogEventTypes.SAFEMODE_CHANGE
		local eventData = SF.LootLog.GetEventDataTemplate(eventType)
		eventData.enabled = enabled
		
		local logEntry = SF.LootLog.new(eventType, eventData)
		if logEntry and self.AddLootLog then
			self:AddLootLog(logEntry)
		end
	end
	
	return true
end

-- Function to set the raid-wide safe mode on combat setting
-- @param boolean v New raid-wide safe mode on combat value
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidWideSafeModeOnCombat(v)
	if not self:IsCurrentUserAdmin() then
		return false, "You must be an admin to change Raid-Wide Safemode on Combat."
	end
	
	local enabled = v and true or false
	self._raidWideSafeModeOnCombat = enabled
	
	-- Create log entry for safemode on combat change
	if SF.LootLog then
		local eventType = SF.LootLogEventTypes.SAFEMODE_ON_COMBAT_CHANGE
		local eventData = SF.LootLog.GetEventDataTemplate(eventType)
		eventData.enabled = enabled
		
		local logEntry = SF.LootLog.new(eventType, eventData)
		if logEntry and self.AddLootLog then
			self:AddLootLog(logEntry)
		end
	end
	
	return true
end

-- ========================================================================
-- Admin Management
-- ========================================================================

-- Function to check if a member ID is an admin of this profile
-- @param string memberId "Name-Realm" of member to check
-- @return boolean isAdmin
function LootProfile:IsAdminMemberId(memberId)
    if type(memberId) ~= "string" or memberId == "" then return false end
    memberId = NormalizeMemberId(memberId)

    for _, id in ipairs(self._adminUsers or {}) do
        if SameMember(id, memberId) then
            return true
        end
    end
    return false
end

-- Function to add an admin member ID to this profile
-- @param string memberId "Name-Realm" of member to add as admin
-- @return boolean success, string|nil errorMessage
function LootProfile:AddAdminMemberId(memberId)
    if SF.Debug then
        SF.Debug:Info("LootProfile", "AddAdminMemberId called with memberId: %s", tostring(memberId))
    end
    
    if type(memberId) ~= "string" or memberId == "" then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to add invalid memberId as admin: %s", tostring(memberId))
        end
        return false, "Invalid member id."
    end
    memberId = NormalizeMemberId(memberId)
    
    if SF.Debug then
        SF.Debug:Info("LootProfile", "Normalized memberId: %s", tostring(memberId))
    end

    if not self:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Current user is not an admin; cannot add admin member IDs")
        end
        return false, "You must be an admin to add admins."
    end

    if not self:getMemberByID(memberId) then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to add non-member as admin: %s", tostring(memberId))
        end
        return false, "That member is not a part of this profile"
    end

    if self:IsAdminMemberId(memberId) then
        if SF.Debug then
            SF.Debug:Info("LootProfile", "Member is already an admin: %s", tostring(memberId))
        end
        return false, "That member is already an admin"
    end

    self._adminUsers = self._adminUsers or {}
    table.insert(self._adminUsers, memberId)
    
    -- Create log entry for admin added
    if SF.LootLog then
        local eventType = SF.LootLogEventTypes.ADMIN_ADDED
        local eventData = SF.LootLog.GetEventDataTemplate(eventType)
        eventData.member = memberId
        
        local logEntry = SF.LootLog.new(eventType, eventData)
        if logEntry and self.AddLootLog then
            self:AddLootLog(logEntry)
        end
    end
    
    if SF.Debug then
        SF.Debug:Info("LootProfile", "Successfully added admin: %s", tostring(memberId))
        SF.Debug:Info("ADMIN_STATUS", "User %s granted admin in profile %s", 
            tostring(memberId), tostring(self._profileName))
    end
    
    return true
end

-- Function to remove an admin member ID from this profile
-- @param string memberId "Name-Realm" of member to remove as admin
-- @return boolean success, string|nil errorMessage
function LootProfile:RemoveAdminMemberId(memberId)
    if type(memberId) ~= "string" or memberId == "" then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to remove invalid memberId from admins: %s", tostring(memberId))
        end
        return false, "Invalid member id."
    end
    memberId = NormalizeMemberId(memberId)

    if not self:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Current user is not an admin; cannot remove admin member IDs")
        end
        return false, "You must be an admin to remove admins."
    end

    if SameMember(memberId, self._owner) then
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to remove owner from admins: %s", tostring(memberId))
        end
        return false, "Cannot remove the owner from admins."
    end

    local admins = self._adminUsers or {}
    for i = #admins, 1, -1 do
        if SameMember(admins[i], memberId) then
            table.remove(admins, i)
            
            -- Create log entry for admin removed
            if SF.LootLog then
                local eventType = SF.LootLogEventTypes.ADMIN_REMOVED
                local eventData = SF.LootLog.GetEventDataTemplate(eventType)
                eventData.member = memberId
                
                local logEntry = SF.LootLog.new(eventType, eventData)
                if logEntry and self.AddLootLog then
                    self:AddLootLog(logEntry)
                end
            end
            
            if SF.Debug then
                SF.Debug:Info("LootProfile", "Removed admin: %s", tostring(memberId))
                SF.Debug:Info("ADMIN_STATUS", "User %s admin revoked in profile %s", 
                    tostring(memberId), tostring(self._profileName))
            end
            
            return true
        end
    end

    return false, "That member is not an admin."
end

-- ========================================================================
-- Exports and Imports
-- ========================================================================

-- Function Export profile header/meta as a network-safe table
function LootProfile:ExportMeta()
    return {
        version         = PROFILE_META_VERSION,
        _profileId      = self._profileId,
        _profileName    = self._profileName,
        _author         = self._author,
        _owner          = self._owner,
    }
end

-- Function Export a full profile snapshot (meta + admins + logs + members + settings) as a network-safe table
-- @param none
-- @return table snapshot
function LootProfile:ExportSnapshot()
    local logsOut = {}
    for i, log in ipairs(self._lootLogs or {}) do
        logsOut[i] = log:ToTable()
    end
    
    local membersOut = {}
    for i, member in ipairs(self._members or {}) do
        if member and type(member.ToTable) == "function" then
            membersOut[i] = member:ToTable()
        end
    end

	self:_EnsureRaidCheckEquipmentSnapshots()
	local equipmentSnapshotsOut = {}
	for memberId, snapshot in pairs(self._raidCheckEquipmentSnapshots) do
		local snapshotCopy = CopyRaidCheckEquipmentSnapshot(snapshot)
		if type(memberId) == "string" and memberId ~= "" and snapshotCopy then
			equipmentSnapshotsOut[memberId] = snapshotCopy
		end
	end

	return {
        version         = PROFILE_SNAPSHOT_VERSION,
        meta            = self:ExportMeta(),
		adminUsers      = CopyArray(self._adminUsers),
		lootLogs        = logsOut,
		members         = membersOut,
		equipmentSnapshots = equipmentSnapshotsOut,
		pointName       = self._pointName or "Points",
		raidCheck       = self:GetRaidCheckConfig(),
	}
end

-- Function Validate profile meta table (structural)
-- @param table meta Profile meta table to validate
-- @return boolean ok
-- @return string|nil errMsg
function LootProfile.ValidateMeta(meta)
    if type(meta) ~= "table" then return false, "Meta is not a table" end
    if meta.version  ~= PROFILE_META_VERSION then
        return false, ("Unsupported meta version %s"):format(tostring(meta.version))
    end

    if type(meta._profileId) ~= "string" or meta._profileId == "" then return false, "Invalid or missing _profileId" end
    if type(meta._profileName) ~= "string" or meta._profileName == "" then return false, "Invalid or missing _profileName" end
    if type(meta._author) ~= "string" or meta._author == "" then return false, "Invalid or missing _author" end
    if type(meta._owner) ~= "string" or meta._owner == "" then return false, "Invalid or missing _owner" end

    return true, nil
end

-- Function Validate snapshot table (structural)
-- @param table snapshot Profile snapshot table to validate
-- @return boolean ok
-- @return string|nil errMsg
function LootProfile.ValidateSnapshot(snapshot)
    if type(snapshot) ~= "table" then return false, "Snapshot is not a table" end
    if snapshot.version ~= PROFILE_SNAPSHOT_VERSION then
        return false, ("Unsupported snapshot version %s"):format(tostring(snapshot.version))
    end

    local ok, err = LootProfile.ValidateMeta(snapshot.meta)
    if not ok then return false, ("Invalid meta in snapshot: %s"):format(err) end

    if type(snapshot.adminUsers) ~= "table" then return false, "Invalid or missing adminUsers" end
    for i, admin in ipairs(snapshot.adminUsers) do
        if type(admin) ~= "string" or admin == "" then
            return false, ("snapshot.adminUsers[%d] is invalid"):format(i)
        end
    end

    if type(snapshot.lootLogs) ~= "table" then return false, "snapshot.logs must be a table" end
    
    -- Validate optional members array (new in this version)
    if snapshot.members ~= nil then
        if type(snapshot.members) ~= "table" then return false, "snapshot.members must be a table or nil" end
    end

	if snapshot.equipmentSnapshots ~= nil then
		if type(snapshot.equipmentSnapshots) ~= "table" then
			return false, "snapshot.equipmentSnapshots must be a table or nil"
		end
		for memberId, equipmentSnapshot in pairs(snapshot.equipmentSnapshots) do
			if type(memberId) ~= "string" or memberId == "" then
				return false, "snapshot.equipmentSnapshots contains an invalid member id"
			end
			if type(equipmentSnapshot) ~= "table" then
				return false, "snapshot.equipmentSnapshots contains an invalid snapshot"
			end
			if equipmentSnapshot.capturedAt ~= nil and type(equipmentSnapshot.capturedAt) ~= "number" then
				return false, "snapshot.equipmentSnapshots.capturedAt must be a number when provided"
			end
			if equipmentSnapshot.averageItemLevel ~= nil and type(equipmentSnapshot.averageItemLevel) ~= "number" then
				return false, "snapshot.equipmentSnapshots.averageItemLevel must be a number when provided"
			end
			if type(equipmentSnapshot.slotsByInventory) ~= "table" then
				return false, "snapshot.equipmentSnapshots.slotsByInventory must be a table"
			end
		end
	end
    
	-- Validate optional pointName (new in this version)
	if snapshot.pointName ~= nil then
		if type(snapshot.pointName) ~= "string" then return false, "snapshot.pointName must be a string or nil" end
	end

	-- Validate optional raidCheck config
	if snapshot.raidCheck ~= nil then
		if type(snapshot.raidCheck) ~= "table" then return false, "snapshot.raidCheck must be a table or nil" end

		if snapshot.raidCheck.slots ~= nil and type(snapshot.raidCheck.slots) ~= "table" then
			return false, "snapshot.raidCheck.slots must be a table when provided"
		end
	end

	if snapshot.rcLootCouncil ~= nil then
		if type(snapshot.rcLootCouncil) ~= "table" then return false, "snapshot.rcLootCouncil must be a table or nil" end
		if snapshot.rcLootCouncil.rollType ~= nil and type(snapshot.rcLootCouncil.rollType) ~= "string" then
			return false, "snapshot.rcLootCouncil.rollType must be a string when provided"
		end
	end

	return true, nil
end

-- Function Import a snapshot into this profile instance
-- Behavior:
--  - If self has no profileId yet, adopt snapshot meta.
--  - If self has a different profileId, reject.
--  - Replace adminUsers with snapshot adminUsers (authoritative list for now)
--  - Replace members with snapshot members (if provided)
--  - Replace pointName with snapshot pointName (if provided)
--  - Merge logs idempotently (dedupe by logId).
-- @param table snapshot Profile snapshot table
-- @param opts table|nil optional:
--     opts.allowUnknownEventType boolean (default true)
-- @return boolean success
-- @return number insertedLogs Number of logs newly inserted
-- @return string|nil errMsg
function LootProfile:ImportSnapshot(snapshot, opts)
    local success, err = LootProfile.ValidateSnapshot(snapshot)
    if not success then return false, 0, err end

    local meta = snapshot.meta

    -- Adopt or validate identity
    if not self._profileId then
        self._profileId = meta._profileId
    elseif self._profileId ~= meta._profileId then
        return false, 0, "Snapshot profileId does not match existing profileId"
    end

    -- Update label/ownership fields (these are not the identity)
    self._profileName   = meta._profileName
    self._author        = meta._author
    self._owner         = meta._owner

    -- Replace admin list (later we may derive this from logs; for now keep it explicit)
    self._adminUsers = CopyArray(snapshot.adminUsers)

    self:_EnsureOwnerIsAdmin()
    
    -- Import members (if provided in snapshot)
    if type(snapshot.members) == "table" then
        self._members = {}
        for _, memberData in ipairs(snapshot.members) do
            if type(memberData) == "table" then
                local m = nil
                if SF.Member and type(SF.Member.FromTable) == "function" then
                    m = SF.Member.FromTable(memberData)
                end
                if m then
                    table.insert(self._members, m)
                end
            end
        end
        
        if SF.Debug then
            SF.Debug:Info("LootProfile", "Imported %d members from snapshot", #self._members)
        end
    end

	self._raidCheckEquipmentSnapshots = {}
	if type(snapshot.equipmentSnapshots) == "table" then
		for memberId, equipmentSnapshot in pairs(snapshot.equipmentSnapshots) do
			local snapshotCopy = CopyRaidCheckEquipmentSnapshot(equipmentSnapshot)
			if type(memberId) == "string" and memberId ~= "" and snapshotCopy then
				snapshotCopy.preparedSlotsByConfig = {}
				self._raidCheckEquipmentSnapshots[NormalizeMemberId(memberId)] = snapshotCopy
			end
		end
	end
    
	-- Import pointName (if provided in snapshot)
	if type(snapshot.pointName) == "string" then
		self._pointName = snapshot.pointName
		
		if SF.Debug then
			SF.Debug:Info("LootProfile", "Imported pointName: %s", self._pointName)
		end
	end

	-- Import raid check settings (if provided)
	if type(snapshot.raidCheck) == "table" then
		self._raidCheckConfig = CopyRaidCheckDefaults()

		if snapshot.raidCheck.enableWhispersPreRaid ~= nil then
			self._raidCheckConfig.enableWhispersPreRaid = snapshot.raidCheck.enableWhispersPreRaid and true or false
		end
		if snapshot.raidCheck.enableWhispersRaid ~= nil then
			self._raidCheckConfig.enableWhispersRaid = snapshot.raidCheck.enableWhispersRaid and true or false
		end
        if snapshot.raidCheck.checkGemsInSockets ~= nil then
            self._raidCheckConfig.checkGemsInSockets = snapshot.raidCheck.checkGemsInSockets and true or false
        end
        if snapshot.raidCheck.requireMetaGem ~= nil then
            self._raidCheckConfig.requireMetaGem = snapshot.raidCheck.requireMetaGem and true or false
        end
		if type(snapshot.raidCheck.slots) == "table" then
			for slotKey, enabled in pairs(snapshot.raidCheck.slots) do
				local normalizedSlotKey = NormalizeSlotKey(slotKey)
				if normalizedSlotKey and RAID_CHECK_SLOT_DEFAULTS[normalizedSlotKey] ~= nil then
					self._raidCheckConfig.slots[normalizedSlotKey] = enabled and true or false
				end
			end
		end
	end

	self:_EnsureRaidCheckConfig()

	-- Merge Logs
	local inserted = self:MergeLogTables(snapshot.lootLogs, opts)

	return true, inserted, nil
end

-- Function Merge a list of LootLog wire tables into this profile
-- Dedupe by logId; stable sort at the end; update logIndex + authorCounters.
-- @param logTables table array of LootLog wire tables
-- @param opts table|nil passed to LootLog.FromTable/ValidateTable
-- @return number insertedLogs Number of logs newly inserted
function LootProfile:MergeLogTables(logTables, opts)
    if type(logTables) ~= "table" then return 0 end

    self._lootLogs = self._lootLogs or {}
    self._logIndex = self._logIndex or {}
    self._authorCounters = self._authorCounters or {}

    local inserted = 0
    local dirtySort = false

    for _, t in ipairs(logTables) do
        local log, err = SF.LootLog.FromTable(t, opts)
        if log then
            local id = log:GetID()
            if not self._logIndex[id] then
                self._logIndex[id] = true
                table.insert(self._lootLogs, log)
                inserted = inserted + 1
                dirtySort = true

                -- Keep authorCounters synced to max seen
                local author = log:GetAuthor()
                local counter = log:GetCounter()
                if type(author) == "string" and type(counter) == "number" then
                    local prev = self._authorCounters[author] or 0
                    if counter > prev then
                        self._authorCounters[author] = counter
                    end
                end
            end
        else
            if SF.Debug then
                SF.Debug:Warn("LootProfile", "Skipping invalid log table: %s", tostring(err))
            end
        end
    end

    if dirtySort then
        table.sort(self._lootLogs, function(a, b) return self:_CompareLogs(a, b) end)
    end

    return inserted
end

-- ========================================================================
-- Private/Helper Methods
-- ========================================================================

-- Function Normalize a profileId using NameUtil (if available)
-- @param string id ProfileId to normalize
-- @return string normalizedId
function LootProfile:_NormalizeId(id)
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(id) or id
    end
    return id
end

-- Function Compare two profileIds for equality using NameUtil (if available)
-- @param string a ProfileId A
-- @param string b ProfileId B
-- @return boolean equal
function LootProfile:_SamePlayer(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

-- Function Ensure memberById index is built
-- @param none
-- @return nil
function LootProfile:_EnsureMemberIndex()
    if self._memberById then return end
    self._memberById = {}

    for _, m in ipairs(self._members or {}) do
        local id = (m.GetFullIdentifier and m:GetFullIdentifier() or m.identifier)
        if type(id) == "string" and id ~= "" then
            self._memberById[id] = m
        end
    end
end

-- Function to ensure the owner is in the admin users list
-- @param none
-- @return nil
function LootProfile:_EnsureOwnerIsAdmin()
    self._adminUsers = self._adminUsers or {}
    for _, id in ipairs(self._adminUsers) do
        if SameMember(id, self._owner) then
            return
        end
    end
    table.insert(self._adminUsers, self._owner)
end

-- ========================================================================
-- Export to Namespace
-- ========================================================================
SF.LootProfile = LootProfile
