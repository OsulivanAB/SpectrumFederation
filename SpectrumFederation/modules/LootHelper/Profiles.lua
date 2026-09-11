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
	enableWhispersRaidPrepared = true,
	whisperTemplatePreRaidMissing = "Spectrum Federation: You're missing the following enchants/gems: {missing}.",
	whisperTemplateRaidMissing = "Spectrum Federation: You're missing the following enchants/gems: {missing}. No new {point_name} awarded.",
	whisperTemplateRaidPrepared = "Spectrum Federation: You've been awarded {points_awarded} {point_name}. Thanks for showing up prepared and on time!",
	pointsAwardPerRaidCheck = 0.5,
	checkGemsInSockets = true,
	requireMetaGem = false,
	slots = RAID_CHECK_SLOT_DEFAULTS,
}

local LOOT_MODE_POINT_BASED = "point_based"
local LOOT_MODE_REWARD_POT = "reward_pot"
local DEDUCTION_TYPE_FLAT = "flat"
local DEDUCTION_TYPE_PERCENT = "percent"

local REWARD_POT_DEFAULTS = {
	startingPotCopper = 0,
	deductionType = DEDUCTION_TYPE_FLAT,
	deductionValue = 0,
}

local RC_LOOT_COUNCIL_INTEGRATION_DEFAULTS = {
	recordAwards = true,
	recordAllAwardTypes = true,
	allowedResponses = {},
	bisResponses = {},
}

local function CopyRCLootCouncilIntegrationDefaults()
	return {
		recordAwards = RC_LOOT_COUNCIL_INTEGRATION_DEFAULTS.recordAwards,
		recordAllAwardTypes = RC_LOOT_COUNCIL_INTEGRATION_DEFAULTS.recordAllAwardTypes,
		allowedResponses = {},
		bisResponses = {},
	}
end

local function IsSequentialLogCounter(counter)
	if SF.LootLog and SF.LootLog.IsSequentialCounter then
		return SF.LootLog.IsSequentialCounter(counter)
	end
	return type(counter) == "number" and counter >= 1 and counter == math.floor(counter)
end

local function NormalizeAllowedResponse(value)
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = strtrim(value)
	if trimmed == "" then
		return nil
	end
	return trimmed
end

local function CopyAllowedResponses(values)
	local copied = {}
	local seen = {}
	if type(values) ~= "table" then
		return copied
	end
	for _, value in ipairs(values) do
		local trimmed = NormalizeAllowedResponse(value)
		if trimmed then
			local key = string.lower(trimmed)
			if not seen[key] then
				seen[key] = true
				copied[#copied + 1] = trimmed
			end
		end
	end
	return copied
end

local function CopyBisResponses(values)
	local copied = {}
	local seen = {}
	if type(values) ~= "table" then
		return copied
	end
	for _, value in ipairs(values) do
		local entry
		if type(value) == "string" then
			local trimmed = NormalizeAllowedResponse(value)
			if trimmed then
				entry = {
					key = "text:" .. string.lower(trimmed),
					text = trimmed,
				}
			end
		elseif type(value) == "table" then
			local text = NormalizeAllowedResponse(value.text or value.label)
			local responseId = value.responseId
			if responseId == nil then
				responseId = value.responseID
			end
			local typeCode = value.typeCode
			if type(typeCode) ~= "string" or strtrim(typeCode) == "" then
				typeCode = nil
			else
				typeCode = strtrim(typeCode)
			end
			local isAwardReason = value.isAwardReason and true or false
			if isAwardReason and responseId ~= nil then
				entry = {
					key = string.format("ctx:awardReason|%s|1", tostring(responseId)),
					text = text or tostring(responseId),
					responseId = responseId,
					isAwardReason = true,
				}
			elseif responseId ~= nil then
				entry = {
					key = string.format("ctx:%s|%s|0", tostring(typeCode or "default"), tostring(responseId)),
					text = text or tostring(responseId),
					typeCode = typeCode or "default",
					responseId = responseId,
					isAwardReason = false,
				}
			elseif text then
				entry = {
					key = "text:" .. string.lower(text),
					text = text,
				}
			end
		end
		if entry and entry.key and not seen[entry.key] then
			seen[entry.key] = true
			copied[#copied + 1] = entry
		end
	end
	return copied
end

local function BisResponseDisplayId(entry)
	if type(entry) == "table" then
		return entry.key or entry.text
	end
	return entry
end

local function BisEntryMatchesCanonical(entry, response, meta)
	if type(entry) ~= "table" then
		return false
	end
	meta = meta or {}
	if entry.responseId ~= nil then
		if meta.responseId == nil then
			return false
		end
		if tostring(entry.responseId) ~= tostring(meta.responseId) then
			return false
		end
		local entryAward = entry.isAwardReason and true or false
		local metaAward = meta.isAwardReason and true or false
		if entryAward ~= metaAward then
			return false
		end
		if entryAward then
			return true
		end
		local entryCode = entry.typeCode or "default"
		local metaCode = meta.typeCode or "default"
		return entryCode == metaCode
	end
	local text = NormalizeAllowedResponse(response)
	if not text or type(entry.text) ~= "string" then
		return false
	end
	return string.lower(entry.text) == string.lower(text)
end

local function NormalizeLootMode(value)
	if value == LOOT_MODE_REWARD_POT then
		return LOOT_MODE_REWARD_POT
	end
	return LOOT_MODE_POINT_BASED
end

local function NormalizeDeductionType(value)
	if value == DEDUCTION_TYPE_PERCENT then
		return DEDUCTION_TYPE_PERCENT
	end
	return DEDUCTION_TYPE_FLAT
end

-- Local user-facing mutators use effective admin/owner. Canonical
-- IsCurrentUserAdmin / IsCurrentUserOwner remain membership queries.
local function CurrentUserHasEffectiveLocalAdmin(profile)
    local Imp = SF.LootHelperImpersonation
    if Imp and Imp.IsEffectiveLocalAdmin then
        return Imp:IsEffectiveLocalAdmin(profile)
    end
    return profile:IsCurrentUserAdmin()
end

local function CurrentUserHasEffectiveLocalOwner(profile)
    local Imp = SF.LootHelperImpersonation
    if Imp and Imp.IsEffectiveLocalOwner and profile.IsCurrentUserOwner and profile:IsCurrentUserOwner() then
        return Imp:IsEffectiveLocalOwner(profile)
    end
    if Imp and Imp.IsActive and Imp:IsActive() then
        local active = SF.lootHelperDB and SF.lootHelperDB.activeProfile
        if active and profile and active.GetProfileId and profile.GetProfileId then
            if active:GetProfileId() == profile:GetProfileId() then
                return false
            end
        elseif active == profile then
            return false
        end
    end
    if profile.IsCurrentUserEffectiveOwner then
        return profile:IsCurrentUserEffectiveOwner()
    end
    return profile:IsCurrentUserOwner()
end

local function NormalizeNonNegativeNumber(value, defaultValue)
	local amount = tonumber(value)
	if amount == nil then
		amount = tonumber(defaultValue) or 0
	end
	if amount < 0 then
		amount = 0
	end
	return amount
end

local function NormalizeCopper(value)
	return math.floor(NormalizeNonNegativeNumber(value, 0))
end

local function NormalizeRaidCheckPointsAward(value)
	local amount = tonumber(value)
	if amount == nil then
		amount = RAID_CHECK_DEFAULTS.pointsAwardPerRaidCheck
	end

	amount = math.max(0, math.min(1, amount))
	amount = math.floor((amount / 0.5) + 0.5) * 0.5
	return amount
end

local function CopyRaidCheckDefaults()
	return {
		enableWhispersPreRaid = RAID_CHECK_DEFAULTS.enableWhispersPreRaid,
		enableWhispersRaid = RAID_CHECK_DEFAULTS.enableWhispersRaid,
		enableWhispersRaidPrepared = RAID_CHECK_DEFAULTS.enableWhispersRaidPrepared,
		whisperTemplatePreRaidMissing = RAID_CHECK_DEFAULTS.whisperTemplatePreRaidMissing,
		whisperTemplateRaidMissing = RAID_CHECK_DEFAULTS.whisperTemplateRaidMissing,
		whisperTemplateRaidPrepared = RAID_CHECK_DEFAULTS.whisperTemplateRaidPrepared,
		pointsAwardPerRaidCheck = RAID_CHECK_DEFAULTS.pointsAwardPerRaidCheck,
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
	cfg.enableWhispersRaidPrepared = cfg.enableWhispersRaidPrepared ~= false
	if type(cfg.whisperTemplatePreRaidMissing) ~= "string" or cfg.whisperTemplatePreRaidMissing == "" then
		cfg.whisperTemplatePreRaidMissing = RAID_CHECK_DEFAULTS.whisperTemplatePreRaidMissing
	end
	if type(cfg.whisperTemplateRaidMissing) ~= "string" or cfg.whisperTemplateRaidMissing == "" then
		cfg.whisperTemplateRaidMissing = RAID_CHECK_DEFAULTS.whisperTemplateRaidMissing
	end
	if type(cfg.whisperTemplateRaidPrepared) ~= "string" or cfg.whisperTemplateRaidPrepared == "" then
		cfg.whisperTemplateRaidPrepared = RAID_CHECK_DEFAULTS.whisperTemplateRaidPrepared
	end
	cfg.pointsAwardPerRaidCheck = NormalizeRaidCheckPointsAward(cfg.pointsAwardPerRaidCheck)
	cfg.checkGemsInSockets = cfg.checkGemsInSockets ~= false
	cfg.requireMetaGem = cfg.requireMetaGem and true or false
end

function LootProfile:_EnsureRewardPotConfig()
	self._lootMode = NormalizeLootMode(self._lootMode)
	self._rewardPotStartingCopper = NormalizeCopper(self._rewardPotStartingCopper)
	self._rewardPotDeductionType = NormalizeDeductionType(self._rewardPotDeductionType)
	self._rewardPotDeductionValue = NormalizeNonNegativeNumber(self._rewardPotDeductionValue, REWARD_POT_DEFAULTS.deductionValue)
	if self._rewardPotDeductionType == DEDUCTION_TYPE_FLAT then
		self._rewardPotDeductionValue = math.floor(self._rewardPotDeductionValue)
	end
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
				itemId = tonumber(slotData.itemId) or nil,
				texture = slotData.texture,
				itemLevel = tonumber(slotData.itemLevel) or nil,
				hasItem = slotData.hasItem and true or nil,
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

local function _GetIntegrityWindowSize()
    local cfg = SF.LootHelperSync and SF.LootHelperSync.cfg
    local size = tonumber(cfg and cfg.integrityWindowSize) or 25
    size = math.floor(size)
    if size < 1 then
        size = 25
    end
    return size
end

local function _FingerprintRollup(rows)
    local checksum = 5381
    table.sort(rows)
    for _, row in ipairs(rows) do
        for i = 1, #row do
            checksum = (checksum * 33 + row:byte(i)) % 2147483647
        end
    end
    return checksum
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

function LootProfile:_AuthorsMatch(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    local Identity = SF.LootHelperIdentity
    if Identity and Identity.SameAuthor then
        return Identity.SameAuthor(a, b)
    end
    if Identity and Identity.SamePlayer then
        return Identity.SamePlayer(a, b)
    end
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

function LootProfile:_LogicalAuthorCounterMax(author)
    local maxSeen = 0
    for existing, counter in pairs(self._authorCounters or {}) do
        local n = tonumber(counter)
        if n and n > maxSeen and self:_AuthorsMatch(existing, author) then
            maxSeen = n
        end
    end
    return maxSeen
end

-- Function: allocate and return the next counter for a given author (used when creating new logs locally).
-- IMPORTANT: This is per-profile, per-author. That's what prevents multi-writer collissions.
-- SamePlayer-equivalent author strings share one counter stream.
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
    local nextCounter = self:_LogicalAuthorCounterMax(author) + 1
    self._authorCounters[author] = nextCounter
    return nextCounter
end

function LootProfile:_MarkIntegritySummaryDirty()
    self._authorWindowSummaryDirty = true
end

function LootProfile:_RefreshLogPositionIndex()
    self._logPositionIndex = {}
    for i, log in ipairs(self._lootLogs or {}) do
        local id = log.GetID and log:GetID() or log._id
        if type(id) == "string" and id ~= "" then
            self._logPositionIndex[id] = i
        end
    end
end

function LootProfile:GetLogFingerprintById(logId)
    if type(logId) ~= "string" or logId == "" then return nil end
    self._logFingerprintIndex = self._logFingerprintIndex or {}
    return self._logFingerprintIndex[logId]
end

function LootProfile:GetLogById(logId)
    if type(logId) ~= "string" or logId == "" then return nil end
    self._logById = self._logById or {}
    return self._logById[logId]
end

-- Per raw `_author` integrity windows. `maxCounter` is the highest counter
-- actually present in the window so protocol-2 peers can compare a partial
-- final window (for example 1 of 1-25) instead of waiting until it is full.
-- SameAuthor aliases stay distinct keys; missing-history repair uses that
-- exact spelling rather than rewriting `_author`.
function LootProfile:ComputeAuthorWindowSummary(windowSize)
    windowSize = tonumber(windowSize) or _GetIntegrityWindowSize()
    windowSize = math.max(1, math.floor(windowSize))

    if not self._authorWindowSummaryDirty
        and self._authorWindowSummarySize == windowSize
        and type(self._authorWindowSummary) == "table"
    then
        return self._authorWindowSummary
    end

    local buckets = {}
    for _, log in ipairs(self._lootLogs or {}) do
        local author = log.GetAuthor and log:GetAuthor() or log._author
        local counter = log.GetCounter and log:GetCounter() or log._counter
        local id = log.GetID and log:GetID() or log._id
        local fingerprint = (log.GetFingerprint and log:GetFingerprint()) or log._fingerprint

        if type(author) == "string"
            and author ~= ""
            and type(counter) == "number"
            and counter >= 1
            and type(id) == "string"
            and id ~= ""
        then
            counter = math.floor(counter)
            local bucketIndex = math.floor((counter - 1) / windowSize)
            local authorBuckets = buckets[author]
            if not authorBuckets then
                authorBuckets = {}
                buckets[author] = authorBuckets
            end

            local bucket = authorBuckets[bucketIndex]
            if not bucket then
                local fromCounter = (bucketIndex * windowSize) + 1
                bucket = {
                    author = author,
                    fromCounter = fromCounter,
                    toCounter = fromCounter + windowSize - 1,
                    count = 0,
                    maxCounter = 0,
                    _rows = {},
                }
                authorBuckets[bucketIndex] = bucket
            end

            bucket.count = bucket.count + 1
            if counter > bucket.maxCounter then
                bucket.maxCounter = counter
            end
            bucket._rows[#bucket._rows + 1] = ("%s=%s"):format(id, tostring(fingerprint or 0))
        end
    end

    local summary = {}
    for author, authorBuckets in pairs(buckets) do
        local rows = {}
        for _, bucket in pairs(authorBuckets) do
            bucket.checksum = _FingerprintRollup(bucket._rows)
            bucket._rows = nil
            rows[#rows + 1] = bucket
        end
        table.sort(rows, function(a, b)
            return a.fromCounter < b.fromCounter
        end)
        summary[author] = rows
    end

    self._authorWindowSummary = summary
    self._authorWindowSummaryDirty = false
    self._authorWindowSummarySize = windowSize
    return summary
end

function LootProfile:_ReplaceLogById(logId, replacementLog)
    if type(logId) ~= "string" or logId == "" then return false end
    if getmetatable(replacementLog) ~= SF.LootLog then return false end

    self._logPositionIndex = self._logPositionIndex or {}
    local idx = self._logPositionIndex[logId]

    if type(idx) ~= "number" or idx < 1 or idx > #(self._lootLogs or {}) then
        for i, log in ipairs(self._lootLogs or {}) do
            local existingId = log.GetID and log:GetID() or log._id
            if existingId == logId then
                idx = i
                break
            end
        end
    end

    if type(idx) ~= "number" then
        return false
    end

    self._lootLogs[idx] = replacementLog
    self._logIndex = self._logIndex or {}
    self._logById = self._logById or {}
    self._logFingerprintIndex = self._logFingerprintIndex or {}
    self._logIndex[logId] = true
    self._logById[logId] = replacementLog
    self._logFingerprintIndex[logId] = replacementLog:GetFingerprint()
    self:_MarkIntegritySummaryDirty()
    return true
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
    instance._logIndex = {}
    instance._logById = {}
    instance._logPositionIndex = {}
    instance._logFingerprintIndex = {}
    instance._authorWindowSummary = {}
    instance._authorWindowSummaryDirty = true
    instance._authorWindowSummarySize = nil
    instance._members = {}
    instance._adminUsers = {}
    instance._activeProfile = false
    instance._authorCounters = {}
    instance._pointName = "Points"
    instance._raidWideSafeMode = false
    instance._raidWideSafeModeOnCombat = false
    instance._raidCheckConfig = CopyRaidCheckDefaults()
    instance._raidCheckEquipmentSnapshots = {}
    instance._lootMode = LOOT_MODE_POINT_BASED
    instance._rewardPotStartingCopper = REWARD_POT_DEFAULTS.startingPotCopper
    instance._rewardPotDeductionType = REWARD_POT_DEFAULTS.deductionType
    instance._rewardPotDeductionValue = REWARD_POT_DEFAULTS.deductionValue
    instance._rcLootCouncilIntegration = CopyRCLootCouncilIntegrationDefaults()
    instance._rcAwardIndex = {}
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
        profile = instance,
        author = instance._author,
        counter = creationCounter,
        skipPermission = true, -- creation is special; no session yet
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

        if type(author) == "string" and IsSequentialLogCounter(counter) then
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
    self._logById = {}
    self._logPositionIndex = {}
    self._logFingerprintIndex = {}
    self._authorCounters = {}
    self._rcAwardIndex = {}

    local lineage = nil
    if SF.LootHelperIdentity and SF.LootHelperIdentity.BuildMainSwapLineage then
        lineage = SF.LootHelperIdentity.BuildMainSwapLineage(self._lootLogs)
    end
    if lineage and #lineage > 0 and SF.LootLog and SF.LootLog.TryNormalizeMainSwapStaleFingerprint then
        for _, log in ipairs(self._lootLogs or {}) do
            SF.LootLog.TryNormalizeMainSwapStaleFingerprint(log, lineage)
        end
    end
    if SF.LootLog and SF.LootLog.TryNormalizeOrphanRewriteStaleFingerprint
        and SF.LootHelperIdentity and SF.LootHelperIdentity.AttributedMemberIds
    then
        local candidates = SF.LootHelperIdentity.AttributedMemberIds(self._lootLogs)
        if #candidates > 0 then
            for _, log in ipairs(self._lootLogs or {}) do
                SF.LootLog.TryNormalizeOrphanRewriteStaleFingerprint(log, candidates)
            end
        end
    end

    for i, log in ipairs(self._lootLogs or {}) do
        local id = log.GetID and log:GetID() or log._id
        if type(id) == "string" and id ~= "" then
            self._logIndex[id] = true
            self._logById[id] = log
            self._logPositionIndex[id] = i
            self._logFingerprintIndex[id] = (log.GetFingerprint and log:GetFingerprint()) or log._fingerprint
        end

        local author = log.GetAuthor and log:GetAuthor() or log._author
        local counter = log.GetCounter and log:GetCounter() or log._counter
        if type(author) == "string" and IsSequentialLogCounter(counter) then
            local prev = self._authorCounters[author] or 0
            if counter > prev then
                self._authorCounters[author] = counter
            end
        end

        local eventType = log.GetEventType and log:GetEventType() or log._eventType
        local data = log.GetEventData and log:GetEventData() or log._data
        if eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.RC_LOOT_COUNCIL)
            and type(data) == "table"
            and type(data.awardKey) == "string"
            and data.awardKey ~= ""
            and type(id) == "string"
        then
            self._rcAwardIndex[data.awardKey] = id
        end
    end

    self:_MarkIntegritySummaryDirty()
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

function LootProfile:IsEffectiveOwner(memberId)
    if self:IsOwner(memberId) then
        return true
    end
    return self:AreSameIdentity(self._owner, memberId)
end

function LootProfile:IsCurrentUserEffectiveOwner()
    local currentUser = SF:GetPlayerFullIdentifier()
    if not currentUser then
        return false
    end
    return self:IsEffectiveOwner(currentUser)
end

function LootProfile:GetIdentityProjection()
    if self._identityProjection then
        return self._identityProjection
    end
    return self:ApplyIdentityProjection({ force = true })
end

function LootProfile:GetIdentityMembers(memberId)
    local Identity = SF.LootHelperIdentity
    memberId = NormalizeMemberId(memberId)
    if not memberId then
        return {}
    end
    local result = self:GetIdentityProjection()
    if Identity and Identity.ComponentMembers then
        return Identity.ComponentMembers(self._lootLogs, memberId, result)
    end
    return { memberId }
end

function LootProfile:AreSameIdentity(memberA, memberB)
    local Identity = SF.LootHelperIdentity
    if not Identity or not Identity.SameIdentity then
        return SameMember(NormalizeMemberId(memberA), NormalizeMemberId(memberB))
    end
    return Identity.SameIdentity(self._lootLogs, memberA, memberB, self:GetIdentityProjection())
end

function LootProfile:GetIdentityPoints(memberId)
    memberId = NormalizeMemberId(memberId)
    local result = self:GetIdentityProjection()
    if memberId and result and result.points then
        return result.points[memberId] or 0
    end
    return 0
end

function LootProfile:GetIdentityAttendance(memberId)
    memberId = NormalizeMemberId(memberId)
    local result = self:GetIdentityProjection()
    if memberId and result and result.attendance then
        local total = result.attendance[memberId] or 0
        if total < 0 then
            return 0
        end
        return total
    end
    return 0
end

function LootProfile:GetIdentityArmor(memberId)
    memberId = NormalizeMemberId(memberId)
    local result = self:GetIdentityProjection()
    if memberId and result and result.armor then
        return result.armor[memberId] or {}
    end
    return {}
end

function LootProfile:GetIdentityBisSlots(memberId)
    memberId = NormalizeMemberId(memberId)
    local result = self:GetIdentityProjection()
    if memberId and result and result.bis and result.bis.slotsByMember then
        return result.bis.slotsByMember[memberId]
    end
    return nil
end

function LootProfile:GetIdentityAwardPool(memberId)
    memberId = NormalizeMemberId(memberId)
    local result = self:GetIdentityProjection()
    if memberId and result and result.bis and result.bis.poolByMember then
        return result.bis.poolByMember[memberId] or {}
    end
    return {}
end

function LootProfile:GetIdentityLegacyOrigins(memberId)
    memberId = NormalizeMemberId(memberId)
    local result = self:GetIdentityProjection()
    if memberId and result and result.bis and result.bis.legacyOriginsByMember then
        return result.bis.legacyOriginsByMember[memberId] or {}
    end
    return {}
end

function LootProfile:IsItemAwareEquipmentPopup()
    local cfg = self:GetRCLootCouncilIntegrationConfig()
    local bisConfigured = cfg.recordAwards and type(cfg.bisResponses) == "table" and #cfg.bisResponses > 0
    local result = self._identityProjection
    local Bis = SF.LootHelperBis
    if Bis and Bis.IsItemAwarePopup then
        return Bis.IsItemAwarePopup(result and result.bis and result.bis.state, bisConfigured)
    end
    return bisConfigured
end

function LootProfile:GetGearOverrideCompatibleAwards(memberId, slot)
    memberId = NormalizeMemberId(memberId)
    local options = {}
    if type(slot) ~= "string" or not memberId then
        return options
    end
    local Bis = SF.LootHelperBis
    if not (Bis and Bis.ClassifyItem and Bis.ItemFitsSlot) then
        return options
    end
    local result = self:GetIdentityProjection()
    local state = result and result.bis and result.bis.state
    local board = result and result.bis and result.bis.slotsByMember and result.bis.slotsByMember[memberId]
    local cell = board and board[slot]
    local pool = self:GetIdentityAwardPool(memberId) or {}
    for i = 1, #pool do
        local award = pool[i]
        if type(award) == "table" and award.kind and award.id then
            local classif = Bis.ClassifyItem(award.itemLink or award.itemString)
            local owner = award.member and self:getMemberByID(award.member)
            local specId = owner and owner.GetSpecId and owner:GetSpecId() or nil
            if classif and Bis.ItemFitsSlot(classif, slot, specId) then
                local key = Bis.AwardRefKey(award.kind, award.id)
                local activeId = state and state.activeByAward and key and state.activeByAward[key]
                local occupyingClicked = activeId and cell and cell.assignmentId == activeId
                local destEmpty = not (cell and cell.state and cell.state ~= "AVAILABLE")
                if not activeId or occupyingClicked or destEmpty then
                    options[#options + 1] = {
                        value = award.kind .. ":" .. award.id,
                        text = string.format("%s %s (%s)", tostring(award.itemLink or award.itemString or "[item]"), award.kind, award.member or ""),
                        awardRef = { kind = award.kind, id = award.id },
                    }
                end
            end
        end
    end
    return options
end

function LootProfile:PlaceGearOverrideAward(memberId, slot, awardRef)
    memberId = NormalizeMemberId(memberId)
    if type(slot) ~= "string" or type(awardRef) ~= "table" then
        return false, "Select loot for an equipment slot."
    end
    local result = self:GetIdentityProjection()
    local state = result and result.bis and result.bis.state
    local board = self:GetIdentityBisSlots(memberId)
    local cell = board and board[slot]
    local key = SF.LootHelperBis and SF.LootHelperBis.AwardRefKey and SF.LootHelperBis.AwardRefKey(awardRef.kind, awardRef.id)
    local activeId = state and state.activeByAward and key and state.activeByAward[key]
    if cell and cell.state == "LEGACY_UNKNOWN" then
        local origins = self:GetIdentityLegacyOrigins(memberId) or {}
        local rec = SF.LootHelperBis and SF.LootHelperBis.LegacyOriginForDisplayedSlot
            and SF.LootHelperBis.LegacyOriginForDisplayedSlot(origins, slot)
        local originId = rec and rec.originLogId
        if not originId then
            return false, "No active legacy origin for that slot."
        end
        return self:ApplyBisOverride("ASSOCIATE_LEGACY", {
            viewMember = memberId,
            awardRef = awardRef,
            legacyOriginLogId = originId,
            assignedSlots = { slot },
        })
    end
    if activeId and (not cell or not cell.assignmentId or cell.assignmentId == activeId or cell.state == "AVAILABLE") then
        return self:ApplyBisOverride("REPLACE", {
            viewMember = memberId,
            targetAssignmentId = activeId,
            awardRef = awardRef,
            assignedSlots = { slot },
            slotBinding = "BOUND",
        })
    end
    if cell and cell.assignmentId then
        return self:ApplyBisOverride("REPLACE", {
            viewMember = memberId,
            targetAssignmentId = cell.assignmentId,
            awardRef = awardRef,
            assignedSlots = { slot },
            slotBinding = "BOUND",
        })
    end
    return self:ApplyBisOverride("ASSIGN", {
        viewMember = memberId,
        awardRef = awardRef,
        assignedSlots = { slot },
        slotBinding = "BOUND",
    })
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

-- Function to check if the current user is the owner of this profile
-- @return boolean isOwner
function LootProfile:IsCurrentUserOwner()
    local currentUser = SF:GetPlayerFullIdentifier()
    if not currentUser then return false end
    return self:IsOwner(currentUser)
end

-- Function to get the loot mode for this profile
-- @return string lootMode
function LootProfile:GetLootMode()
    self:_EnsureRewardPotConfig()
    return self._lootMode
end

-- Function to check whether Reward Pot mode is active
-- @return boolean
function LootProfile:IsRewardPotMode()
    return self:GetLootMode() == LOOT_MODE_REWARD_POT
end

-- Function to check whether Point Based mode is active
-- @return boolean
function LootProfile:IsPointBasedMode()
    return self:GetLootMode() == LOOT_MODE_POINT_BASED
end

-- Function to get Reward Pot configuration
-- @return table
function LootProfile:GetRewardPotConfig()
    self:_EnsureRewardPotConfig()
    return {
        startingPotCopper = self._rewardPotStartingCopper,
        deductionType = self._rewardPotDeductionType,
        deductionValue = self._rewardPotDeductionValue,
    }
end

-- Function to compute the current Reward Pot from starting amount plus logged deltas
-- @return number copper
function LootProfile:GetCurrentRewardPotCopper()
    self:_EnsureRewardPotConfig()
    local copper = self._rewardPotStartingCopper
    local logs = self._lootLogs or {}
    for i = 1, #logs do
        local log = logs[i]
        local eventType = (log.GetEventType and log:GetEventType()) or log._eventType
        if eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.REWARD_POT_CHANGE) then
            local data = (log.GetEventData and log:GetEventData()) or log._data or {}
            local amount = (SF.LootLog and SF.LootLog.GetRewardPotChangeAmount and SF.LootLog.GetRewardPotChangeAmount(data)) or 0
            if data.change == (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.INCREMENT) then
                copper = copper + amount
            elseif data.change == (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.DECREMENT) then
                copper = copper - amount
            end
        end
    end
    if copper < 0 then
        copper = 0
    end
    return copper
end

-- Function to compute a Raid Check pot deduction from the current pot
-- @return number copper
-- @return string|nil deductionType
-- @return number|nil percent
function LootProfile:ComputeRewardPotDeductionCopper()
    self:_EnsureRewardPotConfig()
    local current = self:GetCurrentRewardPotCopper()
    if self._rewardPotDeductionType == DEDUCTION_TYPE_PERCENT then
        local percent = tonumber(self._rewardPotDeductionValue) or 0
        if percent <= 0 or current <= 0 then
            return 0, DEDUCTION_TYPE_PERCENT, percent
        end
        local deducted = math.floor(current * percent / 100)
        if deducted > current then
            deducted = current
        end
        return deducted, DEDUCTION_TYPE_PERCENT, percent
    end

    local amount = math.floor(tonumber(self._rewardPotDeductionValue) or 0)
    if amount > current then
        amount = current
    end
    return amount, DEDUCTION_TYPE_FLAT, nil
end

local function AppendProfileLog(self, eventType, eventData, opts)
    if not SF.LootLog then
        return false, "Loot logs are unavailable."
    end
    opts = opts or {}
    if opts.profile == nil then
        opts.profile = self
    end
    local logEntry = SF.LootLog.new(eventType, eventData, opts)
    if not logEntry then
        return false, "Failed to create loot log entry."
    end
    if self.AddLootLog then
        local addOpts = nil
        if opts.skipBroadcast then
            addOpts = { skipBroadcast = true }
        end
        self:AddLootLog(logEntry, addOpts)
    end
    return true, nil
end

-- Function to set loot mode. Owner only.
-- @param string mode
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetLootMode(mode)
    self:_EnsureRewardPotConfig()
    if not CurrentUserHasEffectiveLocalOwner(self) then
        return false, "Only the profile owner can change loot mode."
    end

    mode = NormalizeLootMode(mode)
    local oldMode = self._lootMode
    if oldMode == mode then
        return true, nil
    end

    local eventType = SF.LootLogEventTypes.LOOT_MODE_CHANGE
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.oldMode = oldMode
    eventData.newMode = mode
    local ok, err = AppendProfileLog(self, eventType, eventData)
    if not ok then
        return false, err
    end

    self._lootMode = mode
    if SF.Debug then
        SF.Debug:Info("LootProfile", "Loot mode changed: %s -> %s", tostring(oldMode), tostring(mode))
    end
    return true, nil
end

-- Function to set Reward Pot configuration. Admin or owner.
-- @param table cfg
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRewardPotConfig(cfg)
    self:_EnsureRewardPotConfig()
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to change Reward Pot settings."
    end

    cfg = type(cfg) == "table" and cfg or {}
    local startingPotCopper = cfg.startingPotCopper
    if startingPotCopper == nil then
        startingPotCopper = self._rewardPotStartingCopper
    end
    local deductionType = cfg.deductionType
    if deductionType == nil then
        deductionType = self._rewardPotDeductionType
    end
    local deductionValue = cfg.deductionValue
    if deductionValue == nil then
        deductionValue = self._rewardPotDeductionValue
    end

    startingPotCopper = NormalizeCopper(startingPotCopper)
    deductionType = NormalizeDeductionType(deductionType)
    deductionValue = NormalizeNonNegativeNumber(deductionValue, 0)
    if deductionType == DEDUCTION_TYPE_FLAT then
        deductionValue = math.floor(deductionValue)
    end

    if startingPotCopper == self._rewardPotStartingCopper
        and deductionType == self._rewardPotDeductionType
        and deductionValue == self._rewardPotDeductionValue then
        return true, nil
    end

    local eventType = SF.LootLogEventTypes.REWARD_POT_CONFIG_CHANGE
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.startingPotCopper = startingPotCopper
    eventData.deductionType = deductionType
    eventData.deductionValue = deductionValue
    local ok, err = AppendProfileLog(self, eventType, eventData)
    if not ok then
        return false, err
    end

    self._rewardPotStartingCopper = startingPotCopper
    self._rewardPotDeductionType = deductionType
    self._rewardPotDeductionValue = deductionValue
    return true, nil
end

-- Function to add or subtract gold from the Reward Pot. Admin or owner.
-- Amount is clamped so the pot never goes below zero; the log stores the applied copper.
-- @param string change INCREMENT or DECREMENT
-- @param number amountCopper
-- @param string|nil reason
-- @param table|nil extra
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:AdjustRewardPot(change, amountCopper, reason, extra)
    self:_EnsureRewardPotConfig()
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to adjust the Reward Pot."
    end

    amountCopper = NormalizeCopper(amountCopper)
    if amountCopper <= 0 then
        return false, "Enter an amount greater than zero."
    end

    local increment = SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.INCREMENT or "INCREMENT"
    local decrement = SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.DECREMENT or "DECREMENT"
    if change ~= increment and change ~= decrement then
        return false, "Invalid Reward Pot adjustment."
    end

    if change == decrement then
        local current = self:GetCurrentRewardPotCopper()
        if current <= 0 then
            return false, "The Reward Pot is already empty."
        end
        if amountCopper > current then
            amountCopper = current
        end
    end

    local eventType = SF.LootLogEventTypes.REWARD_POT_CHANGE
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.change = change
    eventData.amount = amountCopper
    eventData.reason = reason or "MANUAL"
    extra = type(extra) == "table" and extra or nil
    if extra and extra.deductionType then
        eventData.deductionType = extra.deductionType
    end
    if extra and extra.percent ~= nil then
        eventData.percent = extra.percent
    end

    local logOpts = {}
    if extra and extra.logAuthor then
        logOpts.author = extra.logAuthor
    end
    if extra and extra.skipBroadcast then
        logOpts.skipBroadcast = true
    end
    local ok, err = AppendProfileLog(self, eventType, eventData, logOpts)
    if not ok then
        return false, err
    end
    return true, nil
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
		enableWhispersRaidPrepared = self._raidCheckConfig.enableWhispersRaidPrepared ~= false,
		whisperTemplatePreRaidMissing = type(self._raidCheckConfig.whisperTemplatePreRaidMissing) == "string" and self._raidCheckConfig.whisperTemplatePreRaidMissing or RAID_CHECK_DEFAULTS.whisperTemplatePreRaidMissing,
		whisperTemplateRaidMissing = type(self._raidCheckConfig.whisperTemplateRaidMissing) == "string" and self._raidCheckConfig.whisperTemplateRaidMissing or RAID_CHECK_DEFAULTS.whisperTemplateRaidMissing,
		whisperTemplateRaidPrepared = type(self._raidCheckConfig.whisperTemplateRaidPrepared) == "string" and self._raidCheckConfig.whisperTemplateRaidPrepared or RAID_CHECK_DEFAULTS.whisperTemplateRaidPrepared,
		pointsAwardPerRaidCheck = NormalizeRaidCheckPointsAward(self._raidCheckConfig.pointsAwardPerRaidCheck),
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

	if not CurrentUserHasEffectiveLocalAdmin(self) then
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
	if not CurrentUserHasEffectiveLocalAdmin(self) then
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

-- Function toggle whether prepared players are whispered during Raid Check
-- @param boolean enabled
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidCheckWhisperPrepared(enabled)
	self:_EnsureRaidCheckConfig()
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change Raid Check settings."
	end

	self._raidCheckConfig.enableWhispersRaidPrepared = enabled and true or false
	return true, nil
end

local RAID_CHECK_WHISPER_TEMPLATE_KEYS = {
	pre_raid_missing = "whisperTemplatePreRaidMissing",
	raid_missing = "whisperTemplateRaidMissing",
	raid_prepared = "whisperTemplateRaidPrepared",
}

function LootProfile:SetRaidCheckWhisperTemplate(key, template)
	self:_EnsureRaidCheckConfig()
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change Raid Check settings."
	end

	local field = RAID_CHECK_WHISPER_TEMPLATE_KEYS[key]
	if not field then
		return false, "Invalid whisper template key."
	end

	if type(template) ~= "string" or template == "" then
		self._raidCheckConfig[field] = RAID_CHECK_DEFAULTS[field]
	else
		self._raidCheckConfig[field] = template
	end

	return true, nil
end

function LootProfile:ResetRaidCheckWhisperTemplate(key)
	self:_EnsureRaidCheckConfig()
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change Raid Check settings."
	end

	local field = RAID_CHECK_WHISPER_TEMPLATE_KEYS[key]
	if not field then
		return false, "Invalid whisper template key."
	end

	self._raidCheckConfig[field] = RAID_CHECK_DEFAULTS[field]
	return true, nil
end

-- Function set points awarded for prepared players during Raid Check
-- @param number amount
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidCheckPointsAwardPerCheck(amount)
	self:_EnsureRaidCheckConfig()
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change Raid Check settings."
	end

	self._raidCheckConfig.pointsAwardPerRaidCheck = NormalizeRaidCheckPointsAward(amount)
	return true, nil
end

-- Function toggle gem socket validation during Raid Check
-- @param boolean enabled
-- @return boolean success
-- @return string|nil errorMessage
function LootProfile:SetRaidCheckGemSocketsEnabled(enabled)
    self:_EnsureRaidCheckConfig()
    if not CurrentUserHasEffectiveLocalAdmin(self) then
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
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to change Raid Check settings."
    end

    self._raidCheckConfig.requireMetaGem = enabled and true or false
    return true, nil
end

local function CopyRCLootCouncilIntegrationConfig(cfg)
	if type(cfg) ~= "table" then
		return CopyRCLootCouncilIntegrationDefaults()
	end
	return {
		recordAwards = cfg.recordAwards ~= false,
		recordAllAwardTypes = cfg.recordAllAwardTypes ~= false,
		allowedResponses = CopyAllowedResponses(cfg.allowedResponses),
		bisResponses = CopyBisResponses(cfg.bisResponses),
	}
end

local function NormalizeRCConfigGeneration(epoch, seq)
	epoch = tonumber(epoch) or 0
	seq = tonumber(seq) or 0
	return epoch, math.floor(seq)
end

-- Coordinator-assigned RC config generation is (coordEpoch, seq). A newer
-- coordinator epoch wins even when seq collides after takeover; the same
-- epoch still requires a strictly greater seq.
function LootProfile.IsNewerRCConfigGeneration(incomingEpoch, incomingSeq, localEpoch, localSeq)
	incomingEpoch, incomingSeq = NormalizeRCConfigGeneration(incomingEpoch, incomingSeq)
	localEpoch, localSeq = NormalizeRCConfigGeneration(localEpoch, localSeq)
	if incomingEpoch ~= localEpoch then
		return incomingEpoch > localEpoch
	end
	return incomingSeq > localSeq
end

function LootProfile.IsOlderRCConfigGeneration(incomingEpoch, incomingSeq, localEpoch, localSeq)
	incomingEpoch, incomingSeq = NormalizeRCConfigGeneration(incomingEpoch, incomingSeq)
	localEpoch, localSeq = NormalizeRCConfigGeneration(localEpoch, localSeq)
	if incomingEpoch ~= localEpoch then
		return incomingEpoch < localEpoch
	end
	return incomingSeq < localSeq
end

function LootProfile:_EnsureRCLootCouncilIntegrationConfig()
	if type(self._rcLootCouncilIntegration) ~= "table" then
		self._rcLootCouncilIntegration = CopyRCLootCouncilIntegrationDefaults()
		return
	end
	local cfg = self._rcLootCouncilIntegration
	if cfg.recordAwards == nil then
		cfg.recordAwards = RC_LOOT_COUNCIL_INTEGRATION_DEFAULTS.recordAwards
	end
	if cfg.recordAllAwardTypes == nil then
		cfg.recordAllAwardTypes = RC_LOOT_COUNCIL_INTEGRATION_DEFAULTS.recordAllAwardTypes
	end
	cfg.allowedResponses = CopyAllowedResponses(cfg.allowedResponses)
	if type(cfg.bisResponses) ~= "table" then
		cfg.bisResponses = CopyBisResponses(RC_LOOT_COUNCIL_INTEGRATION_DEFAULTS.bisResponses)
	end
	cfg.bisResponses = CopyBisResponses(cfg.bisResponses)
end

-- Live-session followers keep unaccepted edits on a pending copy. Award
-- recording, BiS qualification, and PROFILE_SNAPSHOT always read accepted
-- `_rcLootCouncilIntegration`. Coordinator / local-only edits write accepted.
local function IsRCConfigAuthoritativeLocally(self)
	local Sync = SF.LootHelperSync
	if not Sync or type(Sync.state) ~= "table" then
		return true, nil
	end
	local state = Sync.state
	if state.active ~= true then
		return true, state
	end
	local profileId = self.GetProfileId and self:GetProfileId() or nil
	if state.profileId ~= nil and profileId ~= nil and state.profileId ~= profileId then
		return true, state
	end
	return state.isCoordinator == true, state
end

local function GetMutableRCLootCouncilIntegration(self)
	self:_EnsureRCLootCouncilIntegrationConfig()
	if IsRCConfigAuthoritativeLocally(self) then
		self._pendingRCLootCouncilIntegration = nil
		return self._rcLootCouncilIntegration, false
	end
	if type(self._pendingRCLootCouncilIntegration) ~= "table" then
		self._pendingRCLootCouncilIntegration = CopyRCLootCouncilIntegrationConfig(self._rcLootCouncilIntegration)
	end
	return self._pendingRCLootCouncilIntegration, true
end

local function ConfigIsBisQualifyingResponse(cfg, response, meta)
	if type(cfg) ~= "table" then
		return false
	end
	if type(response) == "table" and meta == nil then
		meta = response
		response = response.response or response.text
	end
	for _, existing in ipairs(cfg.bisResponses or {}) do
		if BisEntryMatchesCanonical(existing, response, meta) then
			return true
		end
	end
	return false
end

local function DiscardPendingRCLootCouncilIntegration(self, reason)
	if type(self._pendingRCLootCouncilIntegration) ~= "table" then
		return
	end
	self._pendingRCLootCouncilIntegration = nil
	if SF.Debug then
		SF.Debug:Verbose("LootProfile", "Discarded unaccepted RC config proposal (%s)", tostring(reason or "unknown"))
	end
end

local function PushRCIntegrationConfig(self)
	local Sync = SF.LootHelperSync
	if not (Sync and Sync.PublishRCIntegrationConfig) then
		DiscardPendingRCLootCouncilIntegration(self, "sync unavailable")
		return true
	end
	local ok, err = Sync:PublishRCIntegrationConfig(self:GetProfileId())
	if ok then
		return true
	end
	if self._pendingRCLootCouncilIntegration then
		-- Followers must not keep an unaccepted proposal that never left this client.
		DiscardPendingRCLootCouncilIntegration(self, err)
		return false, err
	end
	-- Coordinator / local-only accepted mutations stay in place when there is
	-- no session to serialize. "no session" is the expected no-op publish.
	return true
end

function LootProfile:GetRCLootCouncilIntegrationConfig()
	self:_EnsureRCLootCouncilIntegrationConfig()
	return CopyRCLootCouncilIntegrationConfig(self._rcLootCouncilIntegration)
end

function LootProfile:GetProposedRCLootCouncilIntegrationConfig()
	if type(self._pendingRCLootCouncilIntegration) ~= "table" then
		return nil
	end
	return CopyRCLootCouncilIntegrationConfig(self._pendingRCLootCouncilIntegration)
end

-- Apply a strictly validated RC integration config table. Extra keys are ignored.
-- This is the only authority an ordinary admin has over RC settings: the four
-- RC integration fields, never owner/admins/members/logs/loot mode/Reward Pot/Raid Check.
-- @param config table
-- @param options table|nil { skipPermission = bool, skipSync = bool }
-- @return boolean success
-- @return string|nil errorMessage
local function ApplyRCLootCouncilIntegrationFields(target, config)
	if config.recordAwards ~= nil then
		target.recordAwards = config.recordAwards and true or false
	end
	if config.recordAllAwardTypes ~= nil then
		target.recordAllAwardTypes = config.recordAllAwardTypes and true or false
	end
	if config.allowedResponses ~= nil then
		target.allowedResponses = CopyAllowedResponses(config.allowedResponses)
	end
	if config.bisResponses ~= nil then
		target.bisResponses = CopyBisResponses(config.bisResponses)
	end
end

function LootProfile:ApplyRCLootCouncilIntegrationConfig(config, options)
	options = options or {}
	if type(config) ~= "table" then
		return false, "invalid-config"
	end
	self:_EnsureRCLootCouncilIntegrationConfig()
	if not options.skipPermission and not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change RC Loot Council settings."
	end
	if config.allowedResponses ~= nil and type(config.allowedResponses) ~= "table" then
		return false, "invalid-allowed-responses"
	end
	if config.bisResponses ~= nil and type(config.bisResponses) ~= "table" then
		return false, "invalid-bis-responses"
	end
	-- Coordinator SET/REQ apply, and coordinator/local edits, write accepted
	-- state. A live follower proposal stays on the pending copy until SET.
	local target
	if options.skipSync or IsRCConfigAuthoritativeLocally(self) then
		target = self._rcLootCouncilIntegration
		self._pendingRCLootCouncilIntegration = nil
	else
		target = GetMutableRCLootCouncilIntegration(self)
	end
	ApplyRCLootCouncilIntegrationFields(target, config)
	if not options.skipSync then
		return PushRCIntegrationConfig(self)
	end
	return true, nil
end

function LootProfile:SetRCLootCouncilRecordAwards(enabled)
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change RC Loot Council settings."
	end
	local cfg = GetMutableRCLootCouncilIntegration(self)
	cfg.recordAwards = enabled and true or false
	return PushRCIntegrationConfig(self)
end

function LootProfile:SetRCLootCouncilRecordAllAwardTypes(enabled)
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change RC Loot Council settings."
	end
	local cfg = GetMutableRCLootCouncilIntegration(self)
	cfg.recordAllAwardTypes = enabled and true or false
	return PushRCIntegrationConfig(self)
end

function LootProfile:AddRCLootCouncilAllowedResponse(value)
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change RC Loot Council settings."
	end
	local trimmed = NormalizeAllowedResponse(value)
	if not trimmed then
		return false, "Enter a non-empty award type."
	end
	local cfg = GetMutableRCLootCouncilIntegration(self)
	local key = string.lower(trimmed)
	for _, existing in ipairs(cfg.allowedResponses) do
		if string.lower(existing) == key then
			return false, "That award type is already in the list."
		end
	end
	cfg.allowedResponses[#cfg.allowedResponses + 1] = trimmed
	return PushRCIntegrationConfig(self)
end

function LootProfile:RemoveRCLootCouncilAllowedResponse(value)
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change RC Loot Council settings."
	end
	local trimmed = NormalizeAllowedResponse(value)
	if not trimmed then
		return false, "Select an award type to remove."
	end
	local cfg = GetMutableRCLootCouncilIntegration(self)
	if ConfigIsBisQualifyingResponse(cfg, trimmed) then
		return false, "BiS-qualified responses cannot be filtered out of recorded award history."
	end
	local key = string.lower(trimmed)
	local filtered = {}
	local removed = false
	for _, existing in ipairs(cfg.allowedResponses) do
		if string.lower(existing) == key then
			removed = true
		else
			filtered[#filtered + 1] = existing
		end
	end
	if not removed then
		return false, "That award type is not in the list."
	end
	cfg.allowedResponses = filtered
	return PushRCIntegrationConfig(self)
end

function LootProfile:IsBisQualifyingResponse(response, meta)
	self:_EnsureRCLootCouncilIntegrationConfig()
	if type(response) == "table" and meta == nil then
		meta = response
		response = response.response or response.text
	end
	for _, existing in ipairs(self._rcLootCouncilIntegration.bisResponses or {}) do
		if BisEntryMatchesCanonical(existing, response, meta) then
			return true
		end
	end
	return false
end

function LootProfile:AddRCLootCouncilBisResponse(value)
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change RC Loot Council settings."
	end
	local copied = CopyBisResponses({ value })
	local entry = copied[1]
	if not entry then
		return false, "Enter a non-empty BiS response."
	end
	local cfg = GetMutableRCLootCouncilIntegration(self)
	cfg.bisResponses = cfg.bisResponses or {}
	for _, existing in ipairs(cfg.bisResponses) do
		if existing.key == entry.key then
			return false, "That BiS response is already in the list."
		end
	end
	cfg.bisResponses[#cfg.bisResponses + 1] = entry
	return PushRCIntegrationConfig(self)
end

function LootProfile:RemoveRCLootCouncilBisResponse(value)
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change RC Loot Council settings."
	end
	local needle
	if type(value) == "table" then
		needle = value.key or (CopyBisResponses({ value })[1] and CopyBisResponses({ value })[1].key)
	else
		needle = type(value) == "string" and value or nil
	end
	if type(needle) ~= "string" or needle == "" then
		return false, "Select a BiS response to remove."
	end
	local cfg = GetMutableRCLootCouncilIntegration(self)
	local filtered = {}
	local removed = false
	for _, existing in ipairs(cfg.bisResponses or {}) do
		local id = BisResponseDisplayId(existing)
		if id == needle or existing.key == needle or (existing.text and string.lower(existing.text) == string.lower(needle)) then
			removed = true
		else
			filtered[#filtered + 1] = existing
		end
	end
	if not removed then
		return false, "That BiS response is not in the list."
	end
	cfg.bisResponses = filtered
	return PushRCIntegrationConfig(self)
end

function LootProfile:ShouldRecordRCResponse(response, meta)
	local cfg = self:GetRCLootCouncilIntegrationConfig()
	if not cfg.recordAwards then
		return false
	end
	if cfg.recordAllAwardTypes then
		return true
	end
	if self:IsBisQualifyingResponse(response, meta) then
		return true
	end
	if type(response) == "table" then
		meta = meta or response
		response = response.response or response.text
	end
	if type(response) ~= "string" then
		return false
	end
	local needle = string.lower(strtrim(response))
	if needle == "" then
		return false
	end
	for _, allowed in ipairs(cfg.allowedResponses) do
		if string.lower(allowed) == needle then
			return true
		end
	end
	return false
end

function LootProfile:GetRCAwardLogId(awardKey)
	if type(awardKey) ~= "string" or awardKey == "" then
		return nil
	end
	self._rcAwardIndex = self._rcAwardIndex or {}
	return self._rcAwardIndex[awardKey]
end

function LootProfile:TryAddRCLootCouncilAward(canonical)
	if type(canonical) ~= "table" then
		return false, "invalid_award"
	end
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "not_admin"
	end
	if type(canonical.equipLoc) ~= "string" or canonical.equipLoc == "" then
		local classif = SF.LootHelperBis and SF.LootHelperBis.ClassifyItem
			and SF.LootHelperBis.ClassifyItem(canonical.itemLink or canonical.itemString)
		if classif then
			canonical.equipLoc = classif.equipLoc
		end
	end
	if not self:ShouldRecordRCResponse(canonical.response, canonical) then
		return false, "filtered"
	end
	local awardKey = canonical.awardKey
	if type(awardKey) ~= "string" or awardKey == "" then
		return false, "invalid_award"
	end
	if self:GetRCAwardLogId(awardKey) then
		return false, "duplicate"
	end
	if self._logIndex and self._logIndex[awardKey] then
		return false, "duplicate"
	end

	local memberId = canonical.winner
	if type(memberId) ~= "string" or memberId == "" then
		return false, "invalid_award"
	end
	if not self.getMemberByID or not self:getMemberByID(memberId) then
		return false, "not_member"
	end

	local eventType = SF.LootLogEventTypes and SF.LootLogEventTypes.RC_LOOT_COUNCIL
	local eventData = SF.LootLog and SF.LootLog.BuildRCLootCouncilEventData and SF.LootLog.BuildRCLootCouncilEventData(canonical)
	if not eventType or not eventData then
		return false, "invalid_award"
	end

	-- skipPermission is required here: LootLog.new() otherwise checks the
	-- UI-selected lootHelperDB.activeProfile, which can differ from this
	-- session profile. Admin authorization was already verified on self
	-- above, and AddLootLog/_InsertLog still require admin on this profile.
	local logEntry = SF.LootLog.new(eventType, eventData, {
		profile = self,
		author = canonical.awarder,
		timestamp = canonical.timestamp,
		externalId = awardKey,
		counter = 0,
		skipPermission = true,
	})
	if not logEntry then
		return false, "create_failed"
	end

	local inserted = self:AddLootLog(logEntry)
	if not inserted then
		return false, "duplicate"
	end
	self:ApplyRCAutoBisOutcome(logEntry, canonical)
	return true, nil
end

local function WarnLiveBisConflict(self, awardKey, message)
    if type(awardKey) ~= "string" or awardKey == "" then
        return
    end
    self._warnedBisKeys = self._warnedBisKeys or {}
    if self._warnedBisKeys[awardKey] then
        return
    end
    self._warnedBisKeys[awardKey] = true
    if SF.PrintWarning then
        SF:PrintWarning(message)
    end
end

function LootProfile:ApplyRCAutoBisOutcome(rcLog, canonical)
    if type(rcLog) ~= "table" or type(canonical) ~= "table" then
        return false, "invalid_award"
    end
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "not_admin"
    end
    local Bis = SF.LootHelperBis
    if not (Bis and Bis.DecideAutomaticOutcome) then
        return false, "unavailable"
    end
    local awardKey = canonical.awardKey
    local awardMember = canonical.winner
    local response = canonical.response
    local qualified = self:IsBisQualifyingResponse(response, canonical)
    local classif = Bis.ClassifyItem(canonical.itemLink or canonical.itemString)
    local storedSpec
    local member = self:getMemberByID(awardMember)
    if member and member.GetSpecId then
        storedSpec = member:GetSpecId()
    end
    local specId = Bis.ResolveRecipientSpec(awardMember, storedSpec)
    local identityMembers = self:GetIdentityMembers(awardMember)
    local occupancy = {}
    if Bis.LiveOccupancyFromProjection then
        occupancy = Bis.LiveOccupancyFromProjection(self:GetIdentityProjection(), awardMember)
    end
    local decided = Bis.DecideAutomaticOutcome({
        qualified = qualified,
        classif = classif,
        specId = specId,
        occupancy = occupancy,
        identityMembers = identityMembers,
        awardMember = awardMember,
    })
    local eventType = SF.LootLogEventTypes.BIS_OUTCOME
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.sourceLogId = awardKey
    eventData.awardKey = awardKey
    eventData.awardMember = awardMember
    eventData.qualified = decided.qualified
    eventData.outcome = decided.outcome
    eventData.assignedSlots = decided.assignedSlots or {}
    if decided.outcome == Bis.OUTCOME.ASSIGNED then
        eventData.slotBinding = decided.slotBinding
        eventData.assignmentScopeMembers = decided.assignmentScopeMembers
    end
    eventData.specIdUsed = decided.specIdUsed
    eventData.unresolvedReason = decided.unresolvedReason
    eventData.response = response
    eventData.responseId = canonical.responseId
    eventData.isAwardReason = canonical.isAwardReason and true or false
    eventData.typeCode = canonical.typeCode
    eventData.itemLink = canonical.itemLink
    eventData.itemString = canonical.itemString
    if decided.frozen then
        eventData.equipLoc = decided.frozen.equipLoc
        eventData.itemClass = decided.frozen.itemClass
        eventData.itemSubClass = decided.frozen.itemSubClass
        eventData.itemFamily = classif and classif.family
        eventData.isTwoHand = decided.frozen.isTwoHand
    end
    local logEntry = SF.LootLog.new(eventType, eventData, { profile = self })
    if not logEntry then
        return false, "create_failed"
    end
    local inserted = self:AddLootLog(logEntry)
    if not inserted then
        return false, "duplicate"
    end
    if decided.outcome == Bis.OUTCOME.OVERFLOW or decided.outcome == Bis.OUTCOME.UNRESOLVED then
        WarnLiveBisConflict(self, awardKey, string.format(
            "BiS tracking for %s awarded to %s: %s.",
            tostring(canonical.itemLink or "[item]"),
            tostring(awardMember),
            decided.outcome == Bis.OUTCOME.OVERFLOW and "opportunity already consumed" or "could not classify safely"
        ))
    end
    return true, nil
end

function LootProfile:SetMemberSpec(memberId, specId, opts)
    opts = opts or {}
    memberId = NormalizeMemberId(memberId)
    specId = tonumber(specId)
    if type(memberId) ~= "string" or memberId == "" then
        return false, "Select a character."
    end
    if not specId or specId < 1 or specId ~= math.floor(specId) then
        return false, "Select a specialization."
    end
    if not self:getMemberByID(memberId) then
        return false, "That character is not a member of this profile."
    end
    local member = self:getMemberByID(memberId)
    local classToken = member and member.GetClass and member:GetClass()
    if type(classToken) ~= "string" or classToken == "" then
        return false, "That character's class is unknown."
    end
    local SpecWeapons = SF.LootHelperBis and SF.LootHelperBis.SpecWeapons
    if not (SpecWeapons and SpecWeapons.IsKnownSpec and SpecWeapons.IsKnownSpec(specId)) then
        return false, "Select a supported Retail specialization."
    end
    if not SpecWeapons.IsSpecValidForClass(specId, classToken) then
        return false, "That specialization does not belong to this character's class."
    end
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to change specialization."
    end
    local eventType = SF.LootLogEventTypes.SPEC_CHANGE
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.member = memberId
    eventData.specId = specId
    eventData.class = classToken
    if SpecWeapons.SpecName then
        eventData.specName = SpecWeapons.SpecName(specId)
    end
    local logEntry = SF.LootLog.new(eventType, eventData, {
        profile = self,
        skipPermission = opts.skipPermission,
    })
    if not logEntry then
        return false, "Failed to record specialization."
    end
    local inserted = self:AddLootLog(logEntry, {
        skipPermission = opts.skipPermission,
        skipBroadcast = opts.skipBroadcast,
    })
    if not inserted then
        return false, "Failed to record specialization."
    end
    return true, nil
end

function LootProfile:AddManualAward(memberId, itemLink, opts)
    opts = opts or {}
    memberId = NormalizeMemberId(memberId)
    if type(memberId) ~= "string" or memberId == "" then
        return false, "Select a character."
    end
    if not self:getMemberByID(memberId) then
        return false, "That character is not a member of this profile."
    end
    if type(itemLink) ~= "string" or itemLink == "" then
        return false, "Enter an item ID or item link."
    end
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to add loot."
    end
    local canonicalLink, itemString, itemId, normalizeErr
    if SF.LootHelperBis and SF.LootHelperBis.NormalizeAwardItemInput then
        canonicalLink, itemString, itemId, normalizeErr = SF.LootHelperBis.NormalizeAwardItemInput(itemLink)
        if not canonicalLink then
            return false, normalizeErr or "Enter a valid item ID or item link."
        end
    else
        canonicalLink = itemLink
        itemString = (SF.LootLog and SF.LootLog.ExtractItemString and SF.LootLog.ExtractItemString(itemLink)) or itemLink
        itemId = tonumber(itemString and itemString:match("item:(%d+)"))
    end
    local eventType = SF.LootLogEventTypes.MANUAL_AWARD
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.member = memberId
    eventData.itemLink = canonicalLink
    eventData.itemString = itemString
    if itemId then
        eventData.itemId = itemId
    end
    local logEntry = SF.LootLog.new(eventType, eventData, {
        profile = self,
        skipPermission = opts.skipPermission,
    })
    if not logEntry then
        return false, "Failed to add loot."
    end
    local inserted = self:AddLootLog(logEntry, {
        skipPermission = opts.skipPermission,
        skipBroadcast = opts.skipBroadcast,
    })
    if not inserted then
        return false, "Failed to add loot."
    end
    return true, nil
end

function LootProfile:ReverseManualAward(manualAwardId, opts)
    opts = opts or {}
    if type(manualAwardId) ~= "string" or manualAwardId == "" then
        return false, "Select loot to reverse."
    end
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to reverse loot."
    end
    local eventType = SF.LootLogEventTypes.MANUAL_AWARD_REVERSE
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.sourceLogId = manualAwardId
    local logEntry = SF.LootLog.new(eventType, eventData, {
        profile = self,
        skipPermission = opts.skipPermission,
    })
    if not logEntry then
        return false, "Failed to reverse loot."
    end
    local inserted = self:AddLootLog(logEntry, {
        skipPermission = opts.skipPermission,
        skipBroadcast = opts.skipBroadcast,
    })
    if not inserted then
        return false, "Failed to reverse loot."
    end
    return true, nil
end

local function SortedIdentityMembers(profile, memberId)
    local members = profile:GetIdentityMembers(memberId)
    table.sort(members)
    return members
end

function LootProfile:ApplyBisOverride(action, opts)
    opts = opts or {}
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to change Gear Override."
    end
    local actions = SF.LootLogBisOverrideActions or {}
    if action ~= actions.ASSIGN and action ~= actions.CLEAR
        and action ~= actions.REPLACE and action ~= actions.ASSOCIATE_LEGACY then
        return false, "Invalid Gear Override action."
    end
    local eventType = SF.LootLogEventTypes.BIS_OVERRIDE
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.action = action
    if type(opts.viewMember) == "string" and opts.viewMember ~= "" then
        eventData.viewMember = NormalizeMemberId(opts.viewMember)
    end
    if action == actions.CLEAR or action == actions.REPLACE then
        if type(opts.targetAssignmentId) ~= "string" or opts.targetAssignmentId == "" then
            return false, "Select an assignment to change."
        end
        eventData.targetAssignmentId = opts.targetAssignmentId
    end
    if action == actions.ASSIGN or action == actions.REPLACE or action == actions.ASSOCIATE_LEGACY then
        local ref = opts.awardRef
        if type(ref) ~= "table" or (ref.kind ~= "RC" and ref.kind ~= "MANUAL")
            or type(ref.id) ~= "string" or ref.id == "" then
            return false, "Select loot to assign."
        end
        eventData.awardRef = { kind = ref.kind, id = ref.id }
        eventData.sourceLogId = ref.id
        local result = self:GetIdentityProjection()
        local state = result and result.bis and result.bis.state
        local key = SF.LootHelperBis and SF.LootHelperBis.AwardRefKey and SF.LootHelperBis.AwardRefKey(ref.kind, ref.id)
        local award = state and key and state.awards and state.awards[key]
        if not award then
            return false, "That loot is not in the award pool."
        end
        if award.reversed or (state.reversedManual and ref.kind == "MANUAL" and state.reversedManual[ref.id]) then
            return false, "That loot was reversed."
        end
        local activeId = state.activeByAward and state.activeByAward[key]
        if action == actions.ASSIGN and activeId then
            return false, "That loot is already assigned."
        end
        if action == actions.REPLACE then
            local existing = state.assignments and state.assignments[opts.targetAssignmentId]
            if not existing or existing.active ~= true then
                return false, "Select an active assignment to replace."
            end
            local movingSame = key == (SF.LootHelperBis.AwardRefKey(existing.awardRef.kind, existing.awardRef.id))
            if activeId and not movingSame then
                return false, "That loot is already assigned."
            end
        end
        if action == actions.ASSOCIATE_LEGACY then
            if activeId then
                return false, "That loot is already assigned."
            end
        end
    end
    if action == actions.ASSIGN or action == actions.REPLACE then
        eventData.assignedSlots = opts.assignedSlots
        eventData.slotBinding = opts.slotBinding
        local ownerMember
        local award
        local result = self:GetIdentityProjection()
        local state = result and result.bis and result.bis.state
        if state and state.awards then
            local key = SF.LootHelperBis.AwardRefKey(opts.awardRef.kind, opts.awardRef.id)
            award = key and state.awards[key]
            ownerMember = award and award.member
        end
        eventData.assignmentScopeMembers = opts.assignmentScopeMembers
            or SortedIdentityMembers(self, ownerMember or opts.viewMember)
        if type(eventData.assignedSlots) ~= "table" or not SF.LootHelperBis then
            return false, "Select a compatible equipment slot."
        end
        local specId
        local owner = ownerMember and self:getMemberByID(ownerMember)
        if owner and owner.GetSpecId then
            specId = owner:GetSpecId()
        end
        local resolved, resolveErr
        if SF.LootHelperBis.ResolveOverrideSlots then
            resolved, resolveErr = SF.LootHelperBis.ResolveOverrideSlots(
                eventData.assignedSlots,
                award and (award.itemLink or award.itemString),
                specId
            )
        else
            resolved = eventData.assignedSlots
        end
        if not resolved then
            if resolveErr == "MISSING_SPEC" then
                return false, "Set the award owner's specialization before assigning a weapon."
            end
            if resolveErr == "UNKNOWN_COMPAT" then
                return false, "That item cannot be assigned to the selected slot for this specialization."
            end
            if resolveErr == "INCOMPATIBLE_SLOT" or resolveErr == "INVALID_SLOTS" then
                return false, "That item does not fit the selected equipment slot."
            end
            return false, "That item cannot be assigned to the selected slot."
        end
        eventData.assignedSlots = resolved
        local ownerId = ownerMember or opts.viewMember
        local board = self:GetIdentityBisSlots(ownerId)
        -- #278 occupancy is independent of BiS overlay. Replay rejects ASSIGN
        -- and REPLACE via SlotOccupied even when the displayed cell is the
        -- assignment being replaced.
        local armor = self:GetIdentityArmor(ownerId)
        for i = 1, #resolved do
            local slot = resolved[i]
            local cell = board and board[slot]
            if cell and cell.state and cell.state ~= "AVAILABLE" then
                local replacingSelf = action == actions.REPLACE
                    and opts.targetAssignmentId
                    and cell.assignmentId == opts.targetAssignmentId
                if not replacingSelf then
                    return false, "That equipment slot is already occupied."
                end
            end
            if armor and armor[slot] then
                return false, "That equipment slot already has a recorded equipment use."
            end
        end
    end
    if action == actions.ASSOCIATE_LEGACY then
        if type(opts.legacyOriginLogId) ~= "string" or opts.legacyOriginLogId == "" then
            return false, "Select a legacy opportunity."
        end
        local result = self:GetIdentityProjection()
        local state = result and result.bis and result.bis.state
        local ownerMember
        local award
        if state and state.awards and opts.awardRef then
            local key = SF.LootHelperBis and SF.LootHelperBis.AwardRefKey
                and SF.LootHelperBis.AwardRefKey(opts.awardRef.kind, opts.awardRef.id)
            award = key and state.awards[key]
            ownerMember = award and award.member
        end
        local origins = self:GetIdentityLegacyOrigins(ownerMember or opts.viewMember)
        local rec
        for i = 1, #origins do
            if origins[i].originLogId == opts.legacyOriginLogId then
                rec = origins[i]
                break
            end
        end
        if not rec then
            return false, "That legacy opportunity is not active."
        end
        if rec.isOverflow then
            return false, "Overflow origins cannot be associated as a displayed opportunity."
        end
        if state and state.associationByOrigin and state.associationByOrigin[opts.legacyOriginLogId] then
            return false, "That legacy opportunity is already associated."
        end
        eventData.legacyOriginLogId = opts.legacyOriginLogId
        eventData.sourceLogIds = { opts.legacyOriginLogId }
        eventData.assignmentScopeMembers = opts.assignmentScopeMembers
            or SortedIdentityMembers(self, ownerMember or opts.viewMember)
        local originSlot = (type(rec.displayedSlot) == "string" and rec.displayedSlot ~= "") and rec.displayedSlot or rec.slot
        local assigned = opts.assignedSlots
        if type(assigned) ~= "table" or #assigned == 0 then
            assigned = originSlot and { originSlot } or nil
        elseif originSlot and (#assigned ~= 1 or assigned[1] ~= originSlot) then
            return false, "That loot does not match the displayed legacy opportunity."
        end
        if not assigned then
            return false, "That legacy opportunity has no equipment slot."
        end
        local specId
        local owner = ownerMember and self:getMemberByID(ownerMember)
        if owner and owner.GetSpecId then
            specId = owner:GetSpecId()
        end
        local resolved, resolveErr
        if SF.LootHelperBis and SF.LootHelperBis.ResolveOverrideSlots then
            resolved, resolveErr = SF.LootHelperBis.ResolveOverrideSlots(
                assigned,
                award and (award.itemLink or award.itemString),
                specId
            )
        else
            resolved = assigned
        end
        if not resolved then
            return false, "That item does not fit the selected legacy opportunity."
        end
        eventData.assignedSlots = resolved
        eventData.slotBinding = opts.slotBinding or (SF.LootLogBisBindings and SF.LootLogBisBindings.BOUND) or "BOUND"
        local board = self:GetIdentityBisSlots(ownerMember or opts.viewMember)
        local originDisplayed = originSlot
        for i = 1, #resolved do
            local cell = board and board[resolved[i]]
            if cell and cell.state and cell.state ~= "AVAILABLE" then
                local originCell = resolved[i] == originDisplayed and cell.state == "LEGACY_UNKNOWN"
                if not originCell then
                    return false, "That equipment slot is already occupied."
                end
            end
        end
    end
    local logEntry = SF.LootLog.new(eventType, eventData, {
        profile = self,
        skipPermission = opts.skipPermission,
    })
    if not logEntry then
        return false, "Gear Override was rejected."
    end
    local inserted = self:AddLootLog(logEntry, {
        skipPermission = opts.skipPermission,
        skipBroadcast = opts.skipBroadcast,
    })
    if not inserted then
        return false, "Failed to record Gear Override."
    end
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
            
            local logEntry = SF.LootLog.new(eventType, eventData, { profile = self })
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
function LootProfile:AddLootLog(lootLog, opts)
    opts = opts or {}
    local requireAdmin = opts.skipPermission ~= true
    local ok, err = self:_InsertLog(lootLog, { requireAdmin = requireAdmin })
    if ok then
        -- If Sync is loaded, ask it to broadcast this log.
        -- Sync will no-op unless there is an active session AND the profileId matches.
        -- Callers that already know sync is ineligible (mismatch, unannounced
        -- Yes-path session) pass skipBroadcast so we do not hit the wrong-profile path.
        if not opts.skipBroadcast
            and SF
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

    if opts.requireAdmin then
        local eventType = lootLog.GetEventType and lootLog:GetEventType() or lootLog._eventType
        local isLootMode = eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.LOOT_MODE_CHANGE)
        if isLootMode then
            if not CurrentUserHasEffectiveLocalOwner(self) then
                if SF.Debug then
                    SF.Debug("LootProfile", "_InsertLog: Current user is not an effective owner; cannot add loot mode entries")
                end
                return false
            end
        elseif not CurrentUserHasEffectiveLocalAdmin(self) then
            if SF.Debug then
                SF.Debug("LootProfile", "_InsertLog: Current user is not an admin; cannot add loot log entries")
            end
            return false
        end
    end

    self._lootLogs = self._lootLogs or {}
    self._logIndex = self._logIndex or {}
    self._logById = self._logById or {}
    self._logPositionIndex = self._logPositionIndex or {}
    self._logFingerprintIndex = self._logFingerprintIndex or {}
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
    self._logById[id] = lootLog
    self._logFingerprintIndex[id] = lootLog:GetFingerprint()
    local previousLast = self._lootLogs[#self._lootLogs]
    table.insert(self._lootLogs, lootLog)
    
    -- Keep authorCounters synced to max seen
    local author = lootLog:GetAuthor()
    local counter = lootLog:GetCounter()
    if type(author) == "string" and IsSequentialLogCounter(counter) then
        local prev = self:_LogicalAuthorCounterMax(author)
        if counter > prev then
            self._authorCounters[author] = counter
        elseif (self._authorCounters[author] or 0) < prev then
            self._authorCounters[author] = prev
        end
    end

    local eventType = lootLog.GetEventType and lootLog:GetEventType() or lootLog._eventType
    local data = lootLog.GetEventData and lootLog:GetEventData() or lootLog._data
    if eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.RC_LOOT_COUNCIL)
        and type(data) == "table"
        and type(data.awardKey) == "string"
        and data.awardKey ~= ""
    then
        self._rcAwardIndex = self._rcAwardIndex or {}
        self._rcAwardIndex[data.awardKey] = id
    end

    -- Fan-out is only valid for an in-order append. An out-of-order insert is
    -- sorted back into history, and Attendance floors at zero, so a live delta
    -- on the cached total can diverge from a full chronological replay.
    local appendedInOrder = not previousLast or self:_CompareLogs(previousLast, lootLog)
    if appendedInOrder then
        self._logPositionIndex = self._logPositionIndex or {}
        self._logPositionIndex[id] = #self._lootLogs
    else
        table.sort(self._lootLogs, function(a, b)
            return self:_CompareLogs(a, b)
        end)
        self:_RefreshLogPositionIndex()
    end
    self:_MarkIntegritySummaryDirty()
    local Identity = SF.LootHelperIdentity
    if Identity and Identity.AffectsProjection and Identity.AffectsProjection(eventType) then
        if appendedInOrder
            and Identity.CanFanOutBalance and Identity.CanFanOutBalance(eventType)
            and Identity.FanOutBalance and Identity.FanOutBalance(self, lootLog)
        then
            -- Cached identity totals were updated in O(identity size).
        else
            self:ApplyIdentityProjection({ force = true })
        end
    end

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
        self._memberById = nil
        return true
    else
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to add invalid LootProfileMember instance: %s", tostring(member))
        end
        return false
    end
end

-- Function to remove a member from this profile by member ID
-- @param string memberId "Name-Realm" of member to remove
-- @return boolean removed True if a member was removed, false otherwise
function LootProfile:RemoveMemberById(memberId)
    if type(memberId) ~= "string" or memberId == "" then
        return false
    end

    memberId = NormalizeMemberId(memberId)
    local members = self._members or {}
    local removed = false

    for i = #members, 1, -1 do
        local member = members[i]
        local existingId = member and ((member.GetFullIdentifier and member:GetFullIdentifier()) or member.identifier)
        if type(existingId) == "string" and SameMember(existingId, memberId) then
            table.remove(members, i)
            removed = true
        end
    end

    if removed then
        self._memberById = nil
    end

    return removed
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
	if not CurrentUserHasEffectiveLocalAdmin(self) then
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
		
		local logEntry = SF.LootLog.new(eventType, eventData, { profile = self })
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
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change Raid-Wide Safemode."
	end
	
	local enabled = v and true or false
	self._raidWideSafeMode = enabled
	
	-- Create log entry for safemode change
	if SF.LootLog then
		local eventType = SF.LootLogEventTypes.SAFEMODE_CHANGE
		local eventData = SF.LootLog.GetEventDataTemplate(eventType)
		eventData.enabled = enabled
		
		local logEntry = SF.LootLog.new(eventType, eventData, { profile = self })
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
	if not CurrentUserHasEffectiveLocalAdmin(self) then
		return false, "You must be an admin to change Raid-Wide Safemode on Combat."
	end
	
	local enabled = v and true or false
	self._raidWideSafeModeOnCombat = enabled
	
	-- Create log entry for safemode on combat change
	if SF.LootLog then
		local eventType = SF.LootLogEventTypes.SAFEMODE_ON_COMBAT_CHANGE
		local eventData = SF.LootLog.GetEventDataTemplate(eventType)
		eventData.enabled = enabled
		
		local logEntry = SF.LootLog.new(eventType, eventData, { profile = self })
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
function LootProfile:AddAdminMemberId(memberId, opts)
    opts = opts or {}
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

    if not opts.skipPermission and not CurrentUserHasEffectiveLocalAdmin(self) then
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

    if not SF.LootLog then
        return false, "Failed to create admin added log."
    end

    local eventType = SF.LootLogEventTypes.ADMIN_ADDED
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.member = memberId
    if type(opts.sourceLogId) == "string" and opts.sourceLogId ~= "" then
        eventData.sourceLogId = opts.sourceLogId
    end
    local logEntry = SF.LootLog.new(eventType, eventData, { profile = self, skipPermission = opts.skipPermission })
    if not logEntry then
        return false, "Failed to create admin added log."
    end
    local inserted = self:AddLootLog(logEntry, {
        skipPermission = opts.skipPermission,
        skipBroadcast = opts.skipBroadcast,
    })
    if not inserted then
        return false, "Failed to record admin added."
    end

    if SF.Debug then
        SF.Debug:Info("LootProfile", "Successfully added admin: %s", tostring(memberId))
        SF.Debug:Info("ADMIN_STATUS", "User %s granted admin in profile %s",
            tostring(memberId), tostring(self._profileName))
    end

    return self:IsAdminMemberId(memberId)
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

    if not CurrentUserHasEffectiveLocalAdmin(self) then
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
    local removeIndex = nil
    for i = #admins, 1, -1 do
        if SameMember(admins[i], memberId) then
            removeIndex = i
            break
        end
    end
    if not removeIndex then
        return false, "That member is not an admin."
    end

    if not SF.LootLog then
        return false, "Failed to create admin removed log."
    end

    local eventType = SF.LootLogEventTypes.ADMIN_REMOVED
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.member = memberId
    local logEntry = SF.LootLog.new(eventType, eventData, { profile = self })
    if not logEntry then
        return false, "Failed to create admin removed log."
    end
    local inserted = self:AddLootLog(logEntry)
    if not inserted then
        return false, "Failed to record admin removed."
    end

    table.remove(admins, removeIndex)

    if SF.Debug then
        SF.Debug:Info("LootProfile", "Removed admin: %s", tostring(memberId))
        SF.Debug:Info("ADMIN_STATUS", "User %s admin revoked in profile %s",
            tostring(memberId), tostring(self._profileName))
    end

    return true
end

-- Live Main Swap is retired. Historical MAIN_SWAP logs remain as lineage during identity replay.
function LootProfile:TransferMemberHistory()
    return false, "Main Swap has been replaced by Linked Characters."
end

function LootProfile:ApplyIdentityProjection(opts)
    opts = opts or {}
    local Identity = SF.LootHelperIdentity
    if not Identity or not Identity.ApplyToProfileMembers then
        return nil
    end
    if not opts.force and self._identityProjection then
        if Identity.WriteProjection then
            Identity.WriteProjection(self, self._identityProjection)
        end
        return self._identityProjection
    end
    return Identity.ApplyToProfileMembers(self)
end

local function TouchesOwnerIdentity(profile, memberA, memberB)
    if profile:IsEffectiveOwner(memberA) or profile:IsEffectiveOwner(memberB) then
        return true
    end
    return false
end

function LootProfile:LinkCharacters(memberA, memberB, opts)
    opts = opts or {}
    memberA = NormalizeMemberId(memberA)
    memberB = NormalizeMemberId(memberB)
    if type(memberA) ~= "string" or memberA == "" or type(memberB) ~= "string" or memberB == "" then
        return false, "Select two characters."
    end
    if SameMember(memberA, memberB) then
        return false, "Select two different characters."
    end
    if not self:getMemberByID(memberA) or not self:getMemberByID(memberB) then
        return false, "Both characters must be members of this profile."
    end
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to link characters."
    end
    if TouchesOwnerIdentity(self, memberA, memberB) then
        if not CurrentUserHasEffectiveLocalOwner(self) then
            return false, "Only the owner may change the owner's linked identity."
        end
    end

    local Identity = SF.LootHelperIdentity
    if self:AreSameIdentity(memberA, memberB) then
        return false, "Those characters are already linked."
    end

    local before = self._identityProjection
    local conflictCountsA = Identity and Identity.ComponentConflictCounts and Identity.ComponentConflictCounts(before, memberA)
    local conflictCountsB = Identity and Identity.ComponentConflictCounts and Identity.ComponentConflictCounts(before, memberB)

    local adminMembersAtLink = {}
    if Identity and Identity.ComponentAdmins then
        adminMembersAtLink = Identity.ComponentAdmins(self, memberA, memberB)
    end

    local eventType = SF.LootLogEventTypes.CHARACTER_LINK
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.memberA = memberA
    eventData.memberB = memberB
    eventData.adminMembersAtLink = adminMembersAtLink
    local logOpts = {
        profile = self,
        skipPermission = opts.skipPermission,
    }
    local logEntry = SF.LootLog.new(eventType, eventData, logOpts)
    if not logEntry then
        return false, "Failed to create character link log."
    end
    local ok = self:AddLootLog(logEntry, {
        skipBroadcast = opts.skipBroadcast,
        skipPermission = opts.skipPermission,
    })
    if not ok then
        return false, "Failed to record character link."
    end

    local result = self._identityProjection
    if result and Identity and Identity.IntroducedNewConflict
        and Identity.IntroducedNewConflict(
            conflictCountsA,
            conflictCountsB,
            Identity.ComponentConflictCounts and Identity.ComponentConflictCounts(result, memberA)
        )
        and SF.PrintWarning
    then
        SF:PrintWarning("Linked characters share equipment history with overlapping slot usage.")
    end

    local linkedIds = (Identity and Identity.ComponentMembers)
        and Identity.ComponentMembers(self._lootLogs, memberA, result)
        or { memberA, memberB }
    local linkedSet = {}
    for i = 1, #linkedIds do
        linkedSet[linkedIds[i]] = true
    end
    local linkId = logEntry.GetID and logEntry:GetID() or logEntry._id
    if result and result.simulatedAdmins then
        for memberId in pairs(result.simulatedAdmins) do
            if linkedSet[memberId] and not self:IsAdminMemberId(memberId) then
                local sourceLogId = (result.impliedAdminSource and result.impliedAdminSource[memberId]) or linkId
                self:AddAdminMemberId(memberId, {
                    skipPermission = true,
                    skipBroadcast = opts.skipBroadcast,
                    sourceLogId = sourceLogId,
                })
            end
        end
    end

    return true, nil
end

function LootProfile:UnlinkCharacter(memberId, opts)
    opts = opts or {}
    memberId = NormalizeMemberId(memberId)
    if type(memberId) ~= "string" or memberId == "" then
        return false, "Select a character to unlink."
    end
    if not self:getMemberByID(memberId) then
        return false, "That character is not part of this profile."
    end
    if not CurrentUserHasEffectiveLocalAdmin(self) then
        return false, "You must be an admin to unlink characters."
    end
    if self:IsEffectiveOwner(memberId) then
        if not CurrentUserHasEffectiveLocalOwner(self) then
            return false, "Only the owner may change the owner's linked identity."
        end
    end

    local Identity = SF.LootHelperIdentity
    local group = self:GetIdentityMembers(memberId)
    if not group or #group < 2 then
        return false, "That character is not linked to another character."
    end

    local eventType = SF.LootLogEventTypes.CHARACTER_UNLINK
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.member = memberId
    local logEntry = SF.LootLog.new(eventType, eventData, {
        profile = self,
        skipPermission = opts.skipPermission,
    })
    if not logEntry then
        return false, "Failed to create character unlink log."
    end
    local ok = self:AddLootLog(logEntry, {
        skipBroadcast = opts.skipBroadcast,
        skipPermission = opts.skipPermission,
    })
    if not ok then
        return false, "Failed to record character unlink."
    end
    return true, nil
end

function LootProfile:ReconcileIdentityAdmins(opts)
    opts = opts or {}
    local Identity = SF.LootHelperIdentity
    if not Identity or not Identity.Replay then
        return 0
    end
    local legacyAdmins = Identity.EnsureLegacyCanonicalAdmins and Identity.EnsureLegacyCanonicalAdmins(self) or nil
    local result = Identity.Replay(self._lootLogs, { owner = self._owner, legacyAdmins = legacyAdmins })
    local added = 0
    for memberId in pairs(result.simulatedAdmins or {}) do
        if memberId and not self:IsAdminMemberId(memberId) then
            local sourceLogId = result.impliedAdminSource and result.impliedAdminSource[memberId]
            if type(sourceLogId) == "string" and sourceLogId ~= "" then
                if not self:getMemberByID(memberId) and SF.Member and SF.Member.new then
                    local created = SF.Member.new(memberId)
                    if created then
                        self._members = self._members or {}
                        self._members[#self._members + 1] = created
                    end
                end
                local ok = self:AddAdminMemberId(memberId, {
                    skipPermission = true,
                    skipBroadcast = opts.skipBroadcast,
                    sourceLogId = sourceLogId,
                })
                if ok then
                    added = added + 1
                end
            end
        end
    end
    if added > 0 then
        self:ApplyIdentityProjection({ force = true })
    end
    return added
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
		legacyCanonicalAdmins = type(self._legacyCanonicalAdmins) == "table"
			and CopyArray(self._legacyCanonicalAdmins)
			or nil,
		lootLogs        = logsOut,
		members         = membersOut,
		equipmentSnapshots = equipmentSnapshotsOut,
		pointName       = self._pointName or "Points",
		raidCheck       = self:GetRaidCheckConfig(),
		lootMode        = self:GetLootMode(),
		rewardPot       = self:GetRewardPotConfig(),
		rcLootCouncilIntegration = self:GetRCLootCouncilIntegrationConfig(),
		rcConfigSeq     = tonumber(self._rcConfigSeq) or 0,
		rcConfigEpoch   = tonumber(self._rcConfigEpoch) or 0,
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
    if snapshot.legacyCanonicalAdmins ~= nil then
        if type(snapshot.legacyCanonicalAdmins) ~= "table" then
            return false, "snapshot.legacyCanonicalAdmins must be a table or nil"
        end
        for i, admin in ipairs(snapshot.legacyCanonicalAdmins) do
            if type(admin) ~= "string" or admin == "" then
                return false, ("snapshot.legacyCanonicalAdmins[%d] is invalid"):format(i)
            end
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

		if snapshot.raidCheck.pointsAwardPerRaidCheck ~= nil and type(snapshot.raidCheck.pointsAwardPerRaidCheck) ~= "number" then
			return false, "snapshot.raidCheck.pointsAwardPerRaidCheck must be a number when provided"
		end
		if snapshot.raidCheck.slots ~= nil and type(snapshot.raidCheck.slots) ~= "table" then
			return false, "snapshot.raidCheck.slots must be a table when provided"
		end
	end

	if snapshot.lootMode ~= nil then
		if type(snapshot.lootMode) ~= "string" then
			return false, "snapshot.lootMode must be a string when provided"
		end
	end

	if snapshot.rewardPot ~= nil then
		if type(snapshot.rewardPot) ~= "table" then
			return false, "snapshot.rewardPot must be a table or nil"
		end
		if snapshot.rewardPot.startingPotCopper ~= nil and type(snapshot.rewardPot.startingPotCopper) ~= "number" then
			return false, "snapshot.rewardPot.startingPotCopper must be a number when provided"
		end
		if snapshot.rewardPot.deductionType ~= nil and type(snapshot.rewardPot.deductionType) ~= "string" then
			return false, "snapshot.rewardPot.deductionType must be a string when provided"
		end
		if snapshot.rewardPot.deductionValue ~= nil and type(snapshot.rewardPot.deductionValue) ~= "number" then
			return false, "snapshot.rewardPot.deductionValue must be a number when provided"
		end
	end

	-- Legacy compatibility only: older snapshots may still carry rcLootCouncil
	-- metadata. This is not an active RC Loot Council integration.
	if snapshot.rcLootCouncil ~= nil then
		if type(snapshot.rcLootCouncil) ~= "table" then return false, "snapshot.rcLootCouncil must be a table or nil" end
		if snapshot.rcLootCouncil.rollType ~= nil and type(snapshot.rcLootCouncil.rollType) ~= "string" then
			return false, "snapshot.rcLootCouncil.rollType must be a string when provided"
		end
	end

	if snapshot.rcLootCouncilIntegration ~= nil then
		if type(snapshot.rcLootCouncilIntegration) ~= "table" then
			return false, "snapshot.rcLootCouncilIntegration must be a table or nil"
		end
		if snapshot.rcLootCouncilIntegration.allowedResponses ~= nil
			and type(snapshot.rcLootCouncilIntegration.allowedResponses) ~= "table"
		then
			return false, "snapshot.rcLootCouncilIntegration.allowedResponses must be a table when provided"
		end
		if snapshot.rcLootCouncilIntegration.bisResponses ~= nil
			and type(snapshot.rcLootCouncilIntegration.bisResponses) ~= "table"
		then
			return false, "snapshot.rcLootCouncilIntegration.bisResponses must be a table when provided"
		end
	end

	if snapshot.rcConfigSeq ~= nil and type(snapshot.rcConfigSeq) ~= "number" then
		return false, "snapshot.rcConfigSeq must be a number when provided"
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
    if type(snapshot.legacyCanonicalAdmins) == "table" then
        self._legacyCanonicalAdmins = CopyArray(snapshot.legacyCanonicalAdmins)
    else
        self._legacyCanonicalAdmins = nil
    end

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
		if snapshot.raidCheck.enableWhispersRaidPrepared ~= nil then
			self._raidCheckConfig.enableWhispersRaidPrepared = snapshot.raidCheck.enableWhispersRaidPrepared and true or false
		end
		if type(snapshot.raidCheck.whisperTemplatePreRaidMissing) == "string" then
			self._raidCheckConfig.whisperTemplatePreRaidMissing = snapshot.raidCheck.whisperTemplatePreRaidMissing
		end
		if type(snapshot.raidCheck.whisperTemplateRaidMissing) == "string" then
			self._raidCheckConfig.whisperTemplateRaidMissing = snapshot.raidCheck.whisperTemplateRaidMissing
		end
		if type(snapshot.raidCheck.whisperTemplateRaidPrepared) == "string" then
			self._raidCheckConfig.whisperTemplateRaidPrepared = snapshot.raidCheck.whisperTemplateRaidPrepared
		end
		if snapshot.raidCheck.pointsAwardPerRaidCheck ~= nil then
			self._raidCheckConfig.pointsAwardPerRaidCheck = NormalizeRaidCheckPointsAward(snapshot.raidCheck.pointsAwardPerRaidCheck)
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
	self:_EnsureRewardPotConfig()
	self:_EnsureRCLootCouncilIntegrationConfig()

	local incomingSeq = 0
	if type(snapshot.rcConfigSeq) == "number" then
		incomingSeq = math.floor(snapshot.rcConfigSeq)
	end
	local incomingEpoch = 0
	if type(snapshot.rcConfigEpoch) == "number" then
		incomingEpoch = math.floor(snapshot.rcConfigEpoch)
	end
	local localSeq = tonumber(self._rcConfigSeq) or 0
	local localEpoch = tonumber(self._rcConfigEpoch) or 0
	-- Trusted snapshots remain authoritative for joiners, but must not rewind
	-- a newer coordinator-serialized RC_CONFIG_SET already applied locally.
	-- Compare (coordEpoch, seq) so a post-takeover snapshot with a colliding
	-- seq is not treated as equal to a previous coordinator generation.
	if not LootProfile.IsOlderRCConfigGeneration(incomingEpoch, incomingSeq, localEpoch, localSeq) then
		if type(snapshot.rcLootCouncilIntegration) == "table" then
			if snapshot.rcLootCouncilIntegration.recordAwards ~= nil then
				self._rcLootCouncilIntegration.recordAwards = snapshot.rcLootCouncilIntegration.recordAwards and true or false
			end
			if snapshot.rcLootCouncilIntegration.recordAllAwardTypes ~= nil then
				self._rcLootCouncilIntegration.recordAllAwardTypes = snapshot.rcLootCouncilIntegration.recordAllAwardTypes and true or false
			end
			if type(snapshot.rcLootCouncilIntegration.allowedResponses) == "table" then
				self._rcLootCouncilIntegration.allowedResponses = CopyAllowedResponses(snapshot.rcLootCouncilIntegration.allowedResponses)
			end
			if type(snapshot.rcLootCouncilIntegration.bisResponses) == "table" then
				self._rcLootCouncilIntegration.bisResponses = CopyBisResponses(snapshot.rcLootCouncilIntegration.bisResponses)
			end
		end
		self._rcConfigSeq = incomingSeq
		self._rcConfigEpoch = incomingEpoch
		self._pendingRCLootCouncilIntegration = nil
	end

	-- Import loot mode / Reward Pot config only when the snapshot actually contains them.
	-- Older clients omit these fields; keeping local values prevents clobbering.
	if type(snapshot.lootMode) == "string" then
		self._lootMode = NormalizeLootMode(snapshot.lootMode)
	end
	if type(snapshot.rewardPot) == "table" then
		if snapshot.rewardPot.startingPotCopper ~= nil then
			self._rewardPotStartingCopper = NormalizeCopper(snapshot.rewardPot.startingPotCopper)
		end
		if snapshot.rewardPot.deductionType ~= nil then
			self._rewardPotDeductionType = NormalizeDeductionType(snapshot.rewardPot.deductionType)
		end
		if snapshot.rewardPot.deductionValue ~= nil then
			self._rewardPotDeductionValue = NormalizeNonNegativeNumber(snapshot.rewardPot.deductionValue, 0)
			if self._rewardPotDeductionType == DEDUCTION_TYPE_FLAT then
				self._rewardPotDeductionValue = math.floor(self._rewardPotDeductionValue)
			end
		end
	end
	self:_EnsureRewardPotConfig()

	-- Merge Logs
	opts = opts or {}
	if opts.allowMainSwapFingerprintNormalize == nil then
		opts = CopyTableShallow(opts)
		opts.allowMainSwapFingerprintNormalize = true
	end
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

    opts = opts or {}
    if opts.profile == nil then
        opts = CopyTableShallow(opts)
        opts.profile = self
    end
    if opts.allowMainSwapFingerprintNormalize and SF.LootHelperIdentity then
        local lineageSource = {}
        for _, log in ipairs(self._lootLogs or {}) do
            lineageSource[#lineageSource + 1] = log
        end
        for _, t in ipairs(logTables) do
            lineageSource[#lineageSource + 1] = t
        end
        if SF.LootHelperIdentity.BuildMainSwapLineage
            and (type(opts.mainSwapLineage) ~= "table" or #opts.mainSwapLineage == 0)
        then
            local lineage = SF.LootHelperIdentity.BuildMainSwapLineage(lineageSource)
            if lineage and #lineage > 0 then
                opts = CopyTableShallow(opts)
                opts.mainSwapLineage = lineage
            end
        end
        if type(opts.orphanRewriteCandidates) ~= "table" or #opts.orphanRewriteCandidates == 0 then
            if SF.LootHelperIdentity.AttributedMemberIds then
                opts = CopyTableShallow(opts)
                opts.orphanRewriteCandidates = SF.LootHelperIdentity.AttributedMemberIds(lineageSource)
            end
        end
    end
    self._lootLogs = self._lootLogs or {}
    self._logIndex = self._logIndex or {}
    self._logById = self._logById or {}
    self._logPositionIndex = self._logPositionIndex or {}
    self._logFingerprintIndex = self._logFingerprintIndex or {}
    self._authorCounters = self._authorCounters or {}

    local inserted = 0
    local replaced = 0
    local dirtySort = false
    local identityDirty = false
    local mismatches = {}

    for _, t in ipairs(logTables) do
        local log, err = SF.LootLog.FromTable(t, opts)
        if log then
            local id = log:GetID()
            local incomingFingerprint = log:GetFingerprint()
            if not self._logIndex[id] then
                self._logIndex[id] = true
                self._logById[id] = log
                self._logFingerprintIndex[id] = incomingFingerprint
                table.insert(self._lootLogs, log)
                inserted = inserted + 1
                dirtySort = true
                local incomingEventType = log.GetEventType and log:GetEventType() or log._eventType
                if SF.LootHelperIdentity and SF.LootHelperIdentity.AffectsProjection
                    and SF.LootHelperIdentity.AffectsProjection(incomingEventType)
                then
                    identityDirty = true
                end

                -- Keep authorCounters synced to max seen
                local author = log:GetAuthor()
                local counter = log:GetCounter()
                if type(author) == "string" and IsSequentialLogCounter(counter) then
                    local prev = self:_LogicalAuthorCounterMax(author)
                    if counter > prev then
                        self._authorCounters[author] = counter
                    elseif (self._authorCounters[author] or 0) < prev then
                        self._authorCounters[author] = prev
                    end
                end

                local eventType = log.GetEventType and log:GetEventType() or log._eventType
                local data = log.GetEventData and log:GetEventData() or log._data
                if eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.RC_LOOT_COUNCIL)
                    and type(data) == "table"
                    and type(data.awardKey) == "string"
                    and data.awardKey ~= ""
                then
                    self._rcAwardIndex = self._rcAwardIndex or {}
                    self._rcAwardIndex[data.awardKey] = id
                end
            else
                local existingFingerprint = self._logFingerprintIndex[id]
                if existingFingerprint ~= incomingFingerprint then
                    mismatches[#mismatches + 1] = {
                        id = id,
                        author = log:GetAuthor(),
                        counter = log:GetCounter(),
                        localFingerprint = existingFingerprint,
                        remoteFingerprint = incomingFingerprint,
                    }

                    if opts.allowReplaceExisting and self:_ReplaceLogById(id, log) then
                        replaced = replaced + 1
                        dirtySort = true
                        local replacedEventType = log.GetEventType and log:GetEventType() or log._eventType
                        if SF.LootHelperIdentity and SF.LootHelperIdentity.AffectsProjection
                            and SF.LootHelperIdentity.AffectsProjection(replacedEventType)
                        then
                            identityDirty = true
                        end
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
        self:_RefreshLogPositionIndex()
        self:_MarkIntegritySummaryDirty()
        if identityDirty then
            self:ApplyIdentityProjection({ force = true })
        end
    end

    return inserted, {
        inserted = inserted,
        replaced = replaced,
        mismatchCount = #mismatches,
        mismatches = mismatches,
    }
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
SF.LootModes = {
	POINT_BASED = LOOT_MODE_POINT_BASED,
	REWARD_POT = LOOT_MODE_REWARD_POT,
}
SF.RewardPotDeductionTypes = {
	FLAT = DEDUCTION_TYPE_FLAT,
	PERCENT = DEDUCTION_TYPE_PERCENT,
}
