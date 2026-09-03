-- This file contains the Member class for loot profile members
--
-- Point System:
-- Each member has a point balance and 16 armor slots (Head, Shoulder, etc.)
-- Each armor slot can only be "used" once - meaning a member can only spend ONE point on each slot
-- When a slot is toggled to true, the member has used their point for that specific armor piece
-- When a slot is false, the member has not yet used their point for that armor piece
-- This tracks which armor pieces each member has received/claimed

-- Grab the namespace
local addonName, SF = ...

-- Define valid member roles (enforce these two options)
local MEMBER_ROLES = {
    ADMIN = "admin",
    MEMBER = "member"
}
local EQUIPMENT_AWARD_POINT_COST = 1

-- Define all armor slot names (for type safety and easy reference)
local ARMOR_SLOTS = {
    HEAD = "Head",
    SHOULDER = "Shoulder",
    NECK = "Neck",
    BACK = "Back",
    CHEST = "Chest",
    BRACERS = "Bracers",
    WEAPON = "Weapon",
    OFFHAND = "OffHand",
    HANDS = "Hands",
    BELT = "Belt",
    PANTS = "Pants",
    BOOTS = "Boots",
    RING1 = "Ring1",
    RING2 = "Ring2",
    TRINKET1 = "Trinket1",
    TRINKET2 = "Trinket2"
}

-- Local helper function to convert RGB (0-1 range) to hex color code
local function RGBToHex(r, g, b)
	r = math.max(0, math.min(1, tonumber(r) or 1))
	g = math.max(0, math.min(1, tonumber(g) or 1))
	b = math.max(0, math.min(1, tonumber(b) or 1))
	return ("|cff%02x%02x%02x"):format(
		math.floor(r * 255 + 0.5),
		math.floor(g * 255 + 0.5),
		math.floor(b * 255 + 0.5)
	)
end

local function NormalizeClassToken(class)
    if type(class) ~= "string" or class == "" then
        return nil
    end
    local normalized = class:upper():gsub("[%s%-%_]", "")
    if normalized == "" then
        return nil
    end
    return normalized
end

local SYNC_REBUILD_NOTE = "state will be reconciled from logs via sync rebuild"

local function CanCurrentUserEditActiveProfile(profile)
    local activeProfile = profile or (SF.lootHelperDB and SF.lootHelperDB.activeProfile)
    if not activeProfile then
        if SF.Debug then
            SF.Debug:Warn("MEMBER", "No active profile is available for member mutation")
        end
        return false
    end

    local Imp = SF.LootHelperImpersonation
    if Imp and Imp.IsEffectiveLocalAdmin then
        if not Imp:IsEffectiveLocalAdmin(activeProfile) then
            if SF.Debug then
                SF.Debug:Warn("MEMBER", "Current user is not an effective local admin in active profile; cannot change member state")
            end
            return false
        end
        return true
    end

    if type(activeProfile.IsCurrentUserAdmin) ~= "function" then
        if SF.Debug then
            SF.Debug:Warn("MEMBER", "Active profile does not support IsCurrentUserAdmin; cannot change member state")
        end
        return false
    end

    if not activeProfile:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug:Warn("MEMBER", "Current user is not an admin in active profile; cannot change member state")
        end
        return false
    end

    return true
end

local function AddLootLogToActiveProfile(logEntry, opts)
    local profile = opts and opts.profile or (SF.lootHelperDB and SF.lootHelperDB.activeProfile)
    if profile and type(profile.AddLootLog) == "function" then
        local addOpts = nil
        if opts and opts.skipBroadcast then
            addOpts = { skipBroadcast = true }
        end
        profile:AddLootLog(logEntry, addOpts)
        return true
    end

    if SF.Debug then
        SF.Debug:Warn("MEMBER", "Active profile does not support AddLootLog; cannot persist member mutation log")
    end
    return false
end

-- Member class definition
local Member = {}
Member.__index = Member

-- Constructor: Create a new member instance
-- @param identifier (string) - Full character identifier in "Name-Realm" format
-- @param role (string, optional) - Member role ("admin" or "member", defaults to "member")
-- @param class (string, optional) - WoW class name (e.g., "WARRIOR", "PALADIN"), must match SF.WOW_CLASSES keys
-- @return Member instance
function Member.new(identifier, role, class)
    -- Create new instance with metatable
    local instance = setmetatable({}, Member)
    
    -- Normalize identifier using NameUtil if available
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        identifier = SF.NameUtil.NormalizeNameRealm(identifier) or identifier
    end
    
    -- Set default properties
    instance.identifier = identifier or ""
    
    -- Validate and set role (default to "member")
    if role and (role == MEMBER_ROLES.ADMIN or role == MEMBER_ROLES.MEMBER) then
        instance.role = role
    else
        instance.role = MEMBER_ROLES.MEMBER
    end
    
    -- Validate and set class (must exist in SF.WOW_CLASSES)
    local normalizedClass = NormalizeClassToken(class)
    if normalizedClass and SF.WOW_CLASSES and SF.WOW_CLASSES[normalizedClass] then
        instance.class = normalizedClass
    else
        instance.class = nil  -- Unknown or not specified
        if class and SF.Debug then
            SF.Debug:Warn("MEMBER", "Invalid class '%s' provided for member %s", tostring(class), identifier)
        end
    end

    local n, r = instance.identifier:match("^(.-)%-(.-)$")
    instance.member_name = n or instance.identifier
    instance.name = instance.member_name
    instance.member_realm = r or ""
    instance.className = instance.class
    
    instance.pointBalance = 0
    instance.attendanceBalance = 0
    instance.most_recent_pre_raid_check_whisper = nil
    instance.most_recent_raid_check_whisper = nil
    
    -- Initialize armor dictionary with all slots
    -- Each slot tracks whether the member has used their ONE point for that armor piece
    -- false = point not yet used for this slot, true = point has been used for this slot
    instance.armor = {
        Head = false,
        Shoulder = false,
        Neck = false,
        Back = false,
        Chest = false,
        Bracers = false,
        Weapon = false,
        OffHand = false,
        Hands = false,
        Belt = false,
        Pants = false,
        Boots = false,
        Ring1 = false,
        Ring2 = false,
        Trinket1 = false,
        Trinket2 = false
    }
    
    if SF.Debug then
        SF.Debug:Verbose("MEMBER", "Created new member: %s (role: %s)", instance:GetFullIdentifier(), instance.role)
    end
    
    return instance
end

-- Export the Member class and roles to the SF namespace
SF.Member = Member
SF.MemberRoles = MEMBER_ROLES
SF.ArmorSlots = ARMOR_SLOTS

-- Also attach constants to Member class for easy access
Member.MEMBER_ROLES = MEMBER_ROLES
Member.ARMOR_SLOTS = ARMOR_SLOTS

-- Function to update Member Role
-- @param newRole (string) - Use SF.MemberRoles.ADMIN or SF.MemberRoles.MEMBER
-- @return success (boolean) - True if role updated, false otherwise
function Member:SetRole(newRole)

    -- Enforce admin permissions (effective local admin while impersonating)
    if not CanCurrentUserEditActiveProfile() then
        return false
    end
    
    if newRole == MEMBER_ROLES.ADMIN or newRole == MEMBER_ROLES.MEMBER then
        
        -- Create Log Entry for role change
        local logEventType = SF.LootLogEventTypes.ROLE_CHANGE
        local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
        logEventData.member = self:GetFullIdentifier()
        logEventData.newRole = newRole
        local logEntry = SF.LootLog.new(logEventType, logEventData)
        if not logEntry then
            SF:PrintError("Failed to create loot log entry for role change.")
            if SF.Debug then
                SF.Debug:Error("MEMBER", "Failed to create loot log entry for role change for %s", self:GetFullIdentifier())
            end
            return false
        end

        local oldRole = self.role
        self.role = newRole

        -- Add Log Entry to Loot Profile Table
        if SF.lootHelperDB.activeProfile.AddLootLog then
            SF.lootHelperDB.activeProfile:AddLootLog(logEntry)
        else
            if SF.Debug then
                SF.Debug:Warn("MEMBER", "Active profile does not support AddLootLog; cannot log role change")
            end
        end

        if SF.Debug then
            SF.Debug:Info("MEMBER", "%s role changed: %s -> %s", self:GetFullIdentifier(), oldRole, newRole)
        end
        return true
    else
        SF:PrintError("Invalid role specified. Role not changed.")
        if SF.Debug then
            SF.Debug:Warn("MEMBER", "Invalid role change attempted for %s: %s", self:GetFullIdentifier(), tostring(newRole))
        end
        return false
    end
end

-- Function to get Members full identifier (Name-Realm)
-- @return (string) - Full identifier
function Member:GetFullIdentifier()
    return self.identifier
end

-- Get the WoW class for this member
-- @return string|nil - Class name (e.g., "WARRIOR") or nil if not set
function Member:GetClass()
    return self.class
end

-- Wrapper for GetClass (lowercase alias for convenience)
-- @return string|nil - Class name (e.g., "WARRIOR") or nil if not set
function Member:getClass()
	return self:GetClass()
end

-- Get the color code for this member's class
-- @return table|nil - Color table with r, g, b fields (0-1 range) or nil if class not set
function Member:GetClassColor()
    if not self.class or not SF.WOW_CLASSES then
        return nil
    end
    local classData = SF.WOW_CLASSES[self.class]
    if classData and classData.colorCode then
        return classData.colorCode
    end
    return nil
end

-- Get the hex color code string for this member's class (WoW color format)
-- @return string - Hex color code in WoW format (e.g., "|cffC79C6E") or white if class not set
function Member:GetClassColorCode()
	local c = self:GetClassColor()
	if type(c) == "table" then
		return RGBToHex(c.r, c.g, c.b)
	end
	return "|cffffffff"
end

-- Get the texture file path for this member's class icon
-- @return string|nil - Texture file path or nil if class not set
function Member:GetClassTexture()
    if not self.class or not SF.WOW_CLASSES then
        return nil
    end
    local classData = SF.WOW_CLASSES[self.class]
    if classData and classData.textureFile then
        return classData.textureFile
    end
    return nil
end

-- Function to get the current point balance
-- @return (number) - Current point balance
function Member:GetPointBalance()
    return self.pointBalance
end

-- Function to get the current attendance balance
-- @return (number) - Current attendance balance
function Member:GetAttendanceBalance()
    return tonumber(self.attendanceBalance) or 0
end

function Member:GetMostRecentPreRaidCheckWhisper()
    return tonumber(self.most_recent_pre_raid_check_whisper) or nil
end

function Member:GetMostRecentRaidCheckWhisper()
    return tonumber(self.most_recent_raid_check_whisper) or nil
end

function Member:MarkPreRaidCheckWhisperSent(timestamp)
    self.most_recent_pre_raid_check_whisper = tonumber(timestamp) or time()
end

function Member:MarkRaidCheckWhisperSent(timestamp)
    self.most_recent_raid_check_whisper = tonumber(timestamp) or time()
end

-- Function to get all armor slot statuses
-- @return (table) - Dictionary of armor slots with boolean values
function Member:GetArmorStatuses()
    return self.armor
end

-- Function to check if member is an admin
-- @return (boolean) - True if admin, false otherwise
function Member:IsAdmin()
    return self.role == MEMBER_ROLES.ADMIN
end

-- Function to increment point balance by 1
-- @return (boolean) - True if successful, false otherwise
function Member:IncrementPoints(opts)
    if not CanCurrentUserEditActiveProfile(opts and opts.profile) then
        return false
    end
    
    -- Create Log Entry for point increment
	local logEventType = SF.LootLogEventTypes.POINT_CHANGE
	local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
	logEventData.member = self:GetFullIdentifier()
	logEventData.change = SF.LootLogPointChangeTypes.INCREMENT
    if opts and opts.amount ~= nil then
        logEventData.amount = tonumber(opts.amount) or 1
    end
	if opts and opts.reason then
		logEventData.reason = opts.reason
	end

	local logOpts = {}
	if opts and opts.logAuthor then
		logOpts.author = opts.logAuthor
	end
	if opts and opts.timestamp then
		logOpts.timestamp = opts.timestamp
	end
	local logEntry = SF.LootLog.new(logEventType, logEventData, logOpts)
    -- Validate logEntry creation
    if not logEntry then
        SF:PrintError("Failed to create loot log entry for point increment.")
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Failed to create loot log entry for point increment for %s", self:GetFullIdentifier())
        end
        return false
    end

    local amount = SF.LootLog.GetPointChangeAmount(logEventData)
    local oldBalance = self.pointBalance
    self.pointBalance = self.pointBalance + amount
    if SF.Debug then
        local delta = self.pointBalance - oldBalance
        SF.Debug:Info("SYNC_POINTS", "Increment action (mode=apply_delta member=%s old=%s delta=%s new=%s)",
            self:GetFullIdentifier(), tostring(oldBalance), tostring(delta), tostring(self.pointBalance))
    end

    -- Add Log Entry to Loot Profile Table
    AddLootLogToActiveProfile(logEntry, opts)
    
    if SF.Debug then
        SF.Debug:Verbose("MEMBER", "%s points incremented: %s -> %s", self:GetFullIdentifier(), tostring(oldBalance), tostring(self.pointBalance))
        SF.Debug:Verbose("SYNC_POINTS", "Increment action (mode=recompute_on_sync member=%s note=%s)",
            self:GetFullIdentifier(), SYNC_REBUILD_NOTE)
    end
    return true
end

-- Function to decrement point balance by 1
-- Allows negative values (point debt) for edge cases like accidental gear awards
-- @param metadata table|nil Optional log metadata
-- @return (boolean) - True if successful, false otherwise
function Member:DecrementPoints(metadata)
    metadata = metadata or {}

    if not CanCurrentUserEditActiveProfile() then
        return false
    end
    
    -- Create Log Entry for point decrement
    local logEventType = SF.LootLogEventTypes.POINT_CHANGE
    local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
    logEventData.member = self:GetFullIdentifier()
    logEventData.change = SF.LootLogPointChangeTypes.DECREMENT
    if metadata.amount ~= nil then
        logEventData.amount = tonumber(metadata.amount) or 1
    end
    if metadata.reason ~= nil then
        logEventData.reason = tostring(metadata.reason)
    end
    if metadata.source ~= nil then
        logEventData.source = tostring(metadata.source)
    end
    if metadata.rollType ~= nil then
        logEventData.rollType = tostring(metadata.rollType)
    end
    if metadata.itemLink ~= nil then
        logEventData.itemLink = tostring(metadata.itemLink)
    end
    local logOpts = {}
    if metadata.logAuthor ~= nil then
        logOpts.author = tostring(metadata.logAuthor)
    end
    if metadata.timestamp ~= nil then
        logOpts.timestamp = metadata.timestamp
    end
    local logEntry = SF.LootLog.new(logEventType, logEventData, logOpts)
    -- Validate logEntry creation
    if not logEntry then
        SF:PrintError("Failed to create loot log entry for point decrement.")
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Failed to create loot log entry for point decrement for %s", self:GetFullIdentifier())
        end
        return false
    end
    
    local amount = SF.LootLog.GetPointChangeAmount(logEventData)
    local oldBalance = self.pointBalance
    self.pointBalance = self.pointBalance - amount

    -- Add Log Entry to Loot Profile Table
    AddLootLogToActiveProfile(logEntry)
    
    if SF.Debug then
        SF.Debug:Verbose("MEMBER", "%s points decremented: %s -> %s", self:GetFullIdentifier(), tostring(oldBalance), tostring(self.pointBalance))
        if self.pointBalance < 0 then
            SF.Debug:Warn("MEMBER", "%s is now in point debt: %s", self:GetFullIdentifier(), tostring(self.pointBalance))
        end
    end
    return true
end

local ATTENDANCE_STEP = 1

local function IsActiveProfileRewardPot()
    local activeProfile = SF.lootHelperDB and SF.lootHelperDB.activeProfile
    return activeProfile and activeProfile.IsRewardPotMode and activeProfile:IsRewardPotMode()
end

-- Function to increment attendance by 1 (or opts.amount)
-- @param opts table|nil Optional amount, reason, and log author
-- @return (boolean) - True if successful, false otherwise
function Member:IncrementAttendance(opts)
    if not CanCurrentUserEditActiveProfile(opts and opts.profile) then
        return false
    end

    local logEventType = SF.LootLogEventTypes.ATTENDANCE_CHANGE
    local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
    logEventData.member = self:GetFullIdentifier()
    logEventData.change = SF.LootLogPointChangeTypes.INCREMENT
    if opts and opts.amount ~= nil then
        logEventData.amount = tonumber(opts.amount) or ATTENDANCE_STEP
    else
        logEventData.amount = ATTENDANCE_STEP
    end
    if opts and opts.reason then
        logEventData.reason = opts.reason
    end

    local logOpts = {}
    if opts and opts.logAuthor then
        logOpts.author = opts.logAuthor
    end
    if opts and opts.timestamp then
        logOpts.timestamp = opts.timestamp
    end
    local logEntry = SF.LootLog.new(logEventType, logEventData, logOpts)
    if not logEntry then
        SF:PrintError("Failed to create loot log entry for attendance increment.")
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Failed to create loot log entry for attendance increment for %s", self:GetFullIdentifier())
        end
        return false
    end

    local amount = SF.LootLog.GetAttendanceChangeAmount(logEventData)
    local oldBalance = tonumber(self.attendanceBalance) or 0
    self.attendanceBalance = oldBalance + amount

    AddLootLogToActiveProfile(logEntry, opts)

    if SF.Debug then
        SF.Debug:Verbose("MEMBER", "%s attendance incremented: %s -> %s", self:GetFullIdentifier(), tostring(oldBalance), tostring(self.attendanceBalance))
    end
    return true
end

-- Function to decrement attendance, never going below zero
-- @param opts table|nil Optional amount, reason, and log author
-- @return (boolean) - True if successful, false otherwise
function Member:DecrementAttendance(opts)
    if not CanCurrentUserEditActiveProfile() then
        return false
    end

    local oldBalance = tonumber(self.attendanceBalance) or 0
    if oldBalance <= 0 then
        return false
    end

    local requested = ATTENDANCE_STEP
    if opts and opts.amount ~= nil then
        requested = tonumber(opts.amount) or ATTENDANCE_STEP
    end
    if requested <= 0 then
        return false
    end
    if requested > oldBalance then
        requested = oldBalance
    end

    local logEventType = SF.LootLogEventTypes.ATTENDANCE_CHANGE
    local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
    logEventData.member = self:GetFullIdentifier()
    logEventData.change = SF.LootLogPointChangeTypes.DECREMENT
    logEventData.amount = requested
    if opts and opts.reason then
        logEventData.reason = opts.reason
    end

    local logOpts = {}
    if opts and opts.logAuthor then
        logOpts.author = opts.logAuthor
    end
    if opts and opts.timestamp then
        logOpts.timestamp = opts.timestamp
    end
    local logEntry = SF.LootLog.new(logEventType, logEventData, logOpts)
    if not logEntry then
        SF:PrintError("Failed to create loot log entry for attendance decrement.")
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Failed to create loot log entry for attendance decrement for %s", self:GetFullIdentifier())
        end
        return false
    end

    self.attendanceBalance = oldBalance - requested

    AddLootLogToActiveProfile(logEntry)

    if SF.Debug then
        SF.Debug:Verbose("MEMBER", "%s attendance decremented: %s -> %s", self:GetFullIdentifier(), tostring(oldBalance), tostring(self.attendanceBalance))
    end
    return true
end

function Member:ApplyAwardedItem(slot, metadata)
    metadata = metadata or {}

    if not CanCurrentUserEditActiveProfile() then
        return false
    end

    if self.armor[slot] == nil then
        SF:PrintError("Invalid armor slot specified: " .. tostring(slot))
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Invalid award slot '%s' for %s", tostring(slot), self:GetFullIdentifier())
        end
        return false
    end

    if self.armor[slot] == true then
        if SF.Debug then
            SF.Debug:Warn("MEMBER", "Award slot '%s' is already used for %s", tostring(slot), self:GetFullIdentifier())
        end
        return false
    end

    local armorLogEventType = SF.LootLogEventTypes.ARMOR_CHANGE
    local armorLogEventData = SF.LootLog.GetEventDataTemplate(armorLogEventType)
    armorLogEventData.member = self:GetFullIdentifier()
    armorLogEventData.slot = slot
    armorLogEventData.action = SF.LootLogArmorActions.USED
    if metadata.reason ~= nil then
        armorLogEventData.reason = tostring(metadata.reason)
    end
    if metadata.source ~= nil then
        armorLogEventData.source = tostring(metadata.source)
    end
    if metadata.rollType ~= nil then
        armorLogEventData.rollType = tostring(metadata.rollType)
    end
    if metadata.itemLink ~= nil then
        armorLogEventData.itemLink = tostring(metadata.itemLink)
    end

    local logOpts = {}
    if metadata.logAuthor ~= nil then
        logOpts.author = tostring(metadata.logAuthor)
    end
    if metadata.timestamp ~= nil then
        logOpts.timestamp = metadata.timestamp
    end

    local armorLogEntry = SF.LootLog.new(armorLogEventType, armorLogEventData, logOpts)
    if not armorLogEntry then
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Failed to create armor log for awarded item for %s", self:GetFullIdentifier())
        end
        return false
    end

    local skipPoints = IsActiveProfileRewardPot()
    local pointLogEntry = nil
    local pointAmount = EQUIPMENT_AWARD_POINT_COST
    if not skipPoints then
        local pointLogEventType = SF.LootLogEventTypes.POINT_CHANGE
        local pointLogEventData = SF.LootLog.GetEventDataTemplate(pointLogEventType)
        pointLogEventData.member = self:GetFullIdentifier()
        pointLogEventData.change = SF.LootLogPointChangeTypes.DECREMENT
        pointLogEventData.amount = pointAmount
        if metadata.reason ~= nil then
            pointLogEventData.reason = tostring(metadata.reason)
        end
        if metadata.source ~= nil then
            pointLogEventData.source = tostring(metadata.source)
        end
        if metadata.rollType ~= nil then
            pointLogEventData.rollType = tostring(metadata.rollType)
        end
        if metadata.itemLink ~= nil then
            pointLogEventData.itemLink = tostring(metadata.itemLink)
        end

        pointLogEntry = SF.LootLog.new(pointLogEventType, pointLogEventData, logOpts)
        if not pointLogEntry then
            if SF.Debug then
                SF.Debug:Error("MEMBER", "Failed to create point log for awarded item for %s", self:GetFullIdentifier())
            end
            return false
        end
    end

    self.armor[slot] = true
    if not skipPoints then
        self.pointBalance = self.pointBalance - pointAmount
    end

    AddLootLogToActiveProfile(armorLogEntry)
    if pointLogEntry then
        AddLootLogToActiveProfile(pointLogEntry)
    end

    if SF.Debug then
        SF.Debug:Info(
            "MEMBER",
            "Applied awarded item for %s: slot=%s points=%s",
            self:GetFullIdentifier(),
            tostring(slot),
            tostring(self.pointBalance)
        )
    end

    return true
end

-- Function to clear a previously-awarded item from a slot and refund the point.
-- Used by award reassignment handling when an item moves from one member to another.
-- @param slot (string) - Use SF.ArmorSlots constants
-- @param metadata table|nil Optional log metadata
-- @return (boolean) - True if successful, false otherwise
function Member:ClearAwardedItem(slot, metadata)
    metadata = metadata or {}

    if not CanCurrentUserEditActiveProfile() then
        return false
    end

    if self.armor[slot] == nil then
        SF:PrintError("Invalid armor slot specified: " .. tostring(slot))
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Invalid clear-award slot '%s' for %s", tostring(slot), self:GetFullIdentifier())
        end
        return false
    end

    if self.armor[slot] ~= true then
        if SF.Debug then
            SF.Debug:Warn("MEMBER", "Clear-award slot '%s' is not used for %s", tostring(slot), self:GetFullIdentifier())
        end
        return false
    end

    local armorLogEventType = SF.LootLogEventTypes.ARMOR_CHANGE
    local armorLogEventData = SF.LootLog.GetEventDataTemplate(armorLogEventType)
    armorLogEventData.member = self:GetFullIdentifier()
    armorLogEventData.slot = slot
    armorLogEventData.action = SF.LootLogArmorActions.AVAILABLE
    if metadata.reason ~= nil then
        armorLogEventData.reason = tostring(metadata.reason)
    end
    if metadata.source ~= nil then
        armorLogEventData.source = tostring(metadata.source)
    end
    if metadata.rollType ~= nil then
        armorLogEventData.rollType = tostring(metadata.rollType)
    end
    if metadata.itemLink ~= nil then
        armorLogEventData.itemLink = tostring(metadata.itemLink)
    end

    local logOpts = {}
    if metadata.logAuthor ~= nil then
        logOpts.author = tostring(metadata.logAuthor)
    end
    if metadata.timestamp ~= nil then
        logOpts.timestamp = metadata.timestamp
    end

    local armorLogEntry = SF.LootLog.new(armorLogEventType, armorLogEventData, logOpts)
    if not armorLogEntry then
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Failed to create armor clear log for %s", self:GetFullIdentifier())
        end
        return false
    end

    local skipPoints = IsActiveProfileRewardPot()
    local pointLogEntry = nil
    local pointAmount = EQUIPMENT_AWARD_POINT_COST
    if not skipPoints then
        local pointLogEventType = SF.LootLogEventTypes.POINT_CHANGE
        local pointLogEventData = SF.LootLog.GetEventDataTemplate(pointLogEventType)
        pointLogEventData.member = self:GetFullIdentifier()
        pointLogEventData.change = SF.LootLogPointChangeTypes.INCREMENT
        pointLogEventData.amount = pointAmount
        if metadata.reason ~= nil then
            pointLogEventData.reason = tostring(metadata.reason)
        end
        if metadata.source ~= nil then
            pointLogEventData.source = tostring(metadata.source)
        end
        if metadata.rollType ~= nil then
            pointLogEventData.rollType = tostring(metadata.rollType)
        end
        if metadata.itemLink ~= nil then
            pointLogEventData.itemLink = tostring(metadata.itemLink)
        end

        pointLogEntry = SF.LootLog.new(pointLogEventType, pointLogEventData, logOpts)
        if not pointLogEntry then
            if SF.Debug then
                SF.Debug:Error("MEMBER", "Failed to create point clear log for %s", self:GetFullIdentifier())
            end
            return false
        end
    end

    self.armor[slot] = false
    if not skipPoints then
        self.pointBalance = self.pointBalance + pointAmount
    end

    AddLootLogToActiveProfile(armorLogEntry)
    if pointLogEntry then
        AddLootLogToActiveProfile(pointLogEntry)
    end

    if SF.Debug then
        SF.Debug:Info(
            "MEMBER",
            "Cleared awarded item for %s: slot=%s points=%s",
            self:GetFullIdentifier(),
            tostring(slot),
            tostring(self.pointBalance)
        )
    end

    return true
end

-- Function to toggle equipment slot usage (for UI button clicks)
-- Each armor slot can only be used ONCE per member (one point per slot maximum)
-- @param slot (string) - Use SF.ArmorSlots constants
-- @return (boolean) - True if successful, false otherwise
function Member:ToggleEquipment(slot)

    -- Enforce admin permissions (effective local admin while impersonating)
    if not CanCurrentUserEditActiveProfile() then
        return false
    end

    -- Validate slot exists in armor table
    if self.armor[slot] == nil then
        SF:PrintError("Invalid armor slot specified: " .. tostring(slot))
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Invalid armor slot '%s' for %s", tostring(slot), self:GetFullIdentifier())
        end
        return false
    end

    -- Toggle the armor slot usage
    if self.armor[slot] then
        -- Slot is marked as used - toggle to false
        
        -- Create Log Entry for marking armor slot as available again
        local logEventType = SF.LootLogEventTypes.ARMOR_CHANGE
        local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
        logEventData.member = self:GetFullIdentifier()
        logEventData.slot = slot
        logEventData.action = SF.LootLogArmorActions.AVAILABLE
        local logEntry = SF.LootLog.new(logEventType, logEventData)

        -- Validate logEntry creation
        if not logEntry then
            SF:PrintError("Failed to create loot log entry for armor slot toggle.")
            if SF.Debug then
                SF.Debug:Error("MEMBER", "Failed to create loot log entry for armor slot toggle for %s", self:GetFullIdentifier())
            end
            return false
        end

        self.armor[slot] = false

        -- Add Log Entry to Loot Profile Table
        if SF.lootHelperDB.activeProfile.AddLootLog then
            SF.lootHelperDB.activeProfile:AddLootLog(logEntry)
        else
            if SF.Debug then
                SF.Debug:Warn("MEMBER", "Active profile does not support AddLootLog; cannot log point increment")
            end
        end

        if SF.Debug then
            SF.Debug:Info("MEMBER", "%s removed equipment: %s", self:GetFullIdentifier(), slot)
        end
        return true
    else
        -- Slot is currently Available - toggle to used
        
        -- Create Log Entry for marking armor slot as used
        local logEventType = SF.LootLogEventTypes.ARMOR_CHANGE
        local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
        logEventData.member = self:GetFullIdentifier()
        logEventData.slot = slot
        logEventData.action = SF.LootLogArmorActions.USED
        local logEntry = SF.LootLog.new(logEventType, logEventData)

        -- Validate logEntry creation
        if not logEntry then
            SF:PrintError("Failed to create loot log entry for armor slot toggle.")
            if SF.Debug then
                SF.Debug:Error("MEMBER", "Failed to create loot log entry for armor slot toggle for %s", self:GetFullIdentifier())
            end
            return false
        end
        
        self.armor[slot] = true

        -- Add Log Entry to Loot Profile Table
        if SF.lootHelperDB.activeProfile.AddLootLog then
            SF.lootHelperDB.activeProfile:AddLootLog(logEntry)
        else
            if SF.Debug then
                SF.Debug:Warn("MEMBER", "Active profile does not support AddLootLog; cannot log point decrement")
            end
        end
        
        if SF.Debug then
            SF.Debug:Info("MEMBER", "%s equipped item: %s", self:GetFullIdentifier(), slot)
        end
        return true
    end
end

-- TODO: Function to update values based on Loot Logs. Need to wait till we've created the loot Logs to implement
function Member:UpdateFromLootLog()

    if not SF.lootHelperDB.activeProfile then
        if SF.Debug then
            SF.Debug:Warn("MEMBER", "No active loot profile set when updating member from loot logs: %s", self:GetFullIdentifier())
        end
        return
    end
    if not SF.lootHelperDB.activeProfile.GetLootLogs then
        if SF.Debug then
            SF.Debug:Warn("MEMBER", "Active profile does not support GetLootLogs when updating member from loot logs: %s", self:GetFullIdentifier())
        end
        return
    end
    local logs = SF.lootHelperDB.activeProfile:GetLootLogs()
    local filteredLogs = {}
    for _, log in ipairs(logs) do
        if log.eventData.member == self:GetFullIdentifier() then
            table.insert(filteredLogs, log)
        end
    end

    local pointBalance = 0
    local armorStatuses = {}

    -- Loop over each armor type in SF.ArmorSlots to find the most recent entry
    -- If none found, set to false (available)
    -- If found, set to that value
    for slotName, _ in pairs(SF.ArmorSlots) do
        armorStatuses[slotName] = false  -- Default to available
        for i = #filteredLogs, 1, -1 do
            local log = filteredLogs[i]
            if log.eventType == SF.LootLogEventTypes.ARMOR_CHANGE and log.eventData.slot == slotName then
                if log.eventData.action == SF.LootLogArmorActions.USED then
                    armorStatuses[slotName] = true
                else
                    armorStatuses[slotName] = false
                end
                break  -- Found the most recent entry for this slot
            end
        end
    end

    -- Calculate point balance from POINT_CHANGE logs
    pointBalance = 0
    local attendanceBalance = 0
    for _, log in ipairs(filteredLogs) do
        if log.eventType == SF.LootLogEventTypes.POINT_CHANGE then
            local amount = SF.LootLog.GetPointChangeAmount(log.eventData)
            if log.eventData.change == SF.LootLogPointChangeTypes.INCREMENT then
                pointBalance = pointBalance + amount
            elseif log.eventData.change == SF.LootLogPointChangeTypes.DECREMENT then
                pointBalance = pointBalance - amount
            end
        elseif log.eventType == SF.LootLogEventTypes.ATTENDANCE_CHANGE then
            local amount = SF.LootLog.GetAttendanceChangeAmount(log.eventData)
            if log.eventData.change == SF.LootLogPointChangeTypes.INCREMENT then
                attendanceBalance = attendanceBalance + amount
            elseif log.eventData.change == SF.LootLogPointChangeTypes.DECREMENT then
                attendanceBalance = attendanceBalance - amount
            end
        end
    end
    if attendanceBalance < 0 then
        attendanceBalance = 0
    end
    self.pointBalance = pointBalance
    self.attendanceBalance = attendanceBalance
    self.armor = armorStatuses
end

-- ========================================================================
-- Serialization (Export/Import for sync)
-- ========================================================================

-- Function Export member data to a network-safe table
-- @return table memberData
function Member:ToTable()
    -- Note: We manually copy armor table instead of using CopyArray since it's a dictionary, not an array
    local armorCopy = {}
    for k, v in pairs(self.armor or {}) do
        armorCopy[k] = v
    end
    
    return {
        identifier = self.identifier,
        role = self.role,
        class = self.class,
        pointBalance = self.pointBalance,
        attendanceBalance = tonumber(self.attendanceBalance) or 0,
        armor = armorCopy,
        most_recent_pre_raid_check_whisper = tonumber(self.most_recent_pre_raid_check_whisper) or nil,
        most_recent_raid_check_whisper = tonumber(self.most_recent_raid_check_whisper) or nil,
    }
end

-- Function Create a Member instance from a network table
-- @param table t Member data table
-- @return Member|nil member instance or nil if invalid
function Member.FromTable(t)
    if type(t) ~= "table" then return nil end
    if type(t.identifier) ~= "string" or t.identifier == "" then return nil end
    
    local incomingClass = t.class or t.className
    local m = Member.new(t.identifier, t.role, incomingClass)
    if not m then return nil end
    
    -- Set point balance
    m.pointBalance = tonumber(t.pointBalance) or 0
    m.attendanceBalance = tonumber(t.attendanceBalance) or 0
    m.most_recent_pre_raid_check_whisper = tonumber(t.most_recent_pre_raid_check_whisper) or nil
    m.most_recent_raid_check_whisper = tonumber(t.most_recent_raid_check_whisper) or nil
    
    -- Set armor statuses
    if type(t.armor) == "table" then
        for k, v in pairs(t.armor) do
            if m.armor[k] ~= nil then
                m.armor[k] = v and true or false
            else
                -- Warn about unknown armor slot keys from network data (possible schema mismatch)
                if SF.Debug then
                    SF.Debug:Warn("MEMBER", "Unknown armor slot '%s' in FromTable for %s (ignoring)", tostring(k), tostring(m.identifier))
                end
            end
        end
    end
    
    return m
end
