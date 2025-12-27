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
-- @return Member instance
function Member.new(name, realm, role)
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
        self.role = newRole
        -- TODO: Add Log Entry
        return true
    else
        SF:PrintError("Invalid role specified. Role not changed.")
    end
end

-- Function to get Members full identifier (name-realm)
-- @return (string) - Full identifier
function Member:GetFullIdentifier()
    return self.name .. "-" .. self.realm
end

-- Function to increment point balance by 1
-- @return none
function Member:IncrementPoints()
    -- TODO: Enforce admin permissions
    self.pointBalance = self.pointBalance + 1
    -- TODO: Add Log Entry
end

-- Function to decrement point balance by 1
-- Allows negative values (point debt) for edge cases like accidental gear awards
-- @return none
function Member:DecrementPoints()
    -- TODO: Enforce admin permissions
    self.pointBalance = self.pointBalance - 1
    -- TODO: Add Log Entry
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
        return false
    end

    -- Toggle the armor slot usage
    if self.armor[slot] then
        -- Slot is marked as used - toggle to false (member hasn't used their point for this slot)
        -- This returns the point to their balance
        self.armor[slot] = false
        -- TODO: Add Log Entry
        self:IncrementPoints()
        return true
    else
        -- Slot is not used - toggle to true (member is using their ONE point for this slot)
        -- This spends a point from their balance (can result in negative/debt)
        self.armor[slot] = true
        -- TODO: Add Log Entry
        self:DecrementPoints()
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