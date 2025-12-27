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

-- Member class definition
local Member = {}
Member.__index = Member

-- Constructor: Create a new member instance
-- @param name (string) - Character name
-- @param realm (string) - Realm name
-- @param role (string, optional) - Member role ("admin" or "member", defaults to "member")
-- @param class (string, optional) - WoW class name (e.g., "WARRIOR", "PALADIN"), must match SF.WOW_CLASSES keys
-- @return Member instance
function Member.new(name, realm, role, class)
    -- Create new instance with metatable
    local instance = setmetatable({}, Member)
    
    -- Set default properties
    instance.name = name or ""
    instance.realm = realm or ""
    
    -- Validate and set role (default to "member")
    if role and (role == MEMBER_ROLES.ADMIN or role == MEMBER_ROLES.MEMBER) then
        instance.role = role
    else
        instance.role = MEMBER_ROLES.MEMBER
    end
    
    -- Validate and set class (must exist in SF.WOW_CLASSES)
    if class and SF.WOW_CLASSES and SF.WOW_CLASSES[class] then
        instance.class = class
    else
        instance.class = nil  -- Unknown or not specified
        if class and SF.Debug then
            SF.Debug:Warn("MEMBER", "Invalid class '%s' provided for member %s-%s", tostring(class), name, realm)
        end
    end
    
    instance.pointBalance = 0
    
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
    -- TODO: Enforce admin permissions
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

        -- TODO: Add Log Entry to Loot Profile Table

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

-- Function to get Members full identifier (name-realm)
-- @return (string) - Full identifier
function Member:GetFullIdentifier()
    return self.name .. "-" .. self.realm
end

-- Get the WoW class for this member
-- @return string|nil - Class name (e.g., "WARRIOR") or nil if not set
function Member:GetClass()
    return self.class
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
-- @return none
function Member:IncrementPoints()
    -- TODO: Enforce admin permissions
    
    -- Create Log Entry for point increment
    local logEventType = SF.LootLogEventTypes.POINT_CHANGE
    local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
    logEventData.member = self:GetFullIdentifier()
    logEventData.change = SF.LootLogPointChangeTypes.INCREMENT
    local logEntry = SF.LootLog.new(logEventType, logEventData)
    -- Validate logEntry creation
    if not logEntry then
        SF:PrintError("Failed to create loot log entry for point increment.")
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Failed to create loot log entry for point increment for %s", self:GetFullIdentifier())
        end
        return
    end

    local oldBalance = self.pointBalance
    self.pointBalance = self.pointBalance + 1

    -- TODO: Add Log Entry to Loot Profile Table
    if SF.Debug then
        SF.Debug:Verbose("MEMBER", "%s points incremented: %d -> %d", self:GetFullIdentifier(), oldBalance, self.pointBalance)
    end
end

-- Function to decrement point balance by 1
-- Allows negative values (point debt) for edge cases like accidental gear awards
-- @return none
function Member:DecrementPoints()
    -- TODO: Enforce admin permissions
    
    -- Create Log Entry for point decrement
    local logEventType = SF.LootLogEventTypes.POINT_CHANGE
    local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
    logEventData.member = self:GetFullIdentifier()
    logEventData.change = SF.LootLogPointChangeTypes.DECREMENT
    local logEntry = SF.LootLog.new(logEventType, logEventData)
    -- Validate logEntry creation
    if not logEntry then
        SF:PrintError("Failed to create loot log entry for point decrement.")
        if SF.Debug then
            SF.Debug:Error("MEMBER", "Failed to create loot log entry for point decrement for %s", self:GetFullIdentifier())
        end
        return
    end
    
    local oldBalance = self.pointBalance
    self.pointBalance = self.pointBalance - 1

    -- TODO: Add Log Entry to Loot Profile Table
    
    if SF.Debug then
        SF.Debug:Verbose("MEMBER", "%s points decremented: %d -> %d", self:GetFullIdentifier(), oldBalance, self.pointBalance)
        if self.pointBalance < 0 then
            SF.Debug:Warn("MEMBER", "%s is now in point debt: %d", self:GetFullIdentifier(), self.pointBalance)
        end
    end
end

-- Function to toggle equipment slot usage (for UI button clicks)
-- Each armor slot can only be used ONCE per member (one point per slot maximum)
-- @param slot (string) - Use SF.ArmorSlots constants
-- @return (boolean) - True if successful, false otherwise
function Member:ToggleEquipment(slot)
    -- TODO: Enforce admin permissions

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

        self:IncrementPoints()
        self.armor[slot] = false
        -- TODO: Add Log Entry to Loot Profile Table
        if SF.Debug then
            SF.Debug:Info("MEMBER", "%s removed equipment: %s (points: %d)", self:GetFullIdentifier(), slot, self.pointBalance)
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
        
        self:DecrementPoints()
        self.armor[slot] = true
        -- TODO: Add Log Entry to Loot Profile Table
        if SF.Debug then
            SF.Debug:Info("MEMBER", "%s equipped item: %s (points: %d)", self:GetFullIdentifier(), slot, self.pointBalance)
        end
        return true
    end
end

-- TODO: Function to update values based on Loot Logs. Need to wait till we've created the loot Logs to implement
function Member:UpdateFromLootLog()
    -- Filter loot logs for this member
    -- Create variable for filtered logs to armor updates
    -- Create variable for filtered logs to point updates

    -- For each armor slot, find most recent log entry and update based on that entry. If none, set to false
    
    -- Calculate point balance based on point log entries
end

