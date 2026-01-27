-- Grab the namespace
local addonName, SF = ...

-- ============================================================================
-- Name Utility - Canonical Name-Realm Normalization
-- ============================================================================
-- Purpose: Provide ONE authoritative way to normalize player names across
-- the entire addon to prevent comparison/key mismatches from whitespace,
-- case sensitivity, and missing realm names.
-- ============================================================================

SF.NameUtil = SF.NameUtil or {}
local NameUtil = SF.NameUtil

-- ============================================================================
-- Core Normalization
-- ============================================================================

--- Normalize a player name to canonical "Name-Realm" format
-- @param nameOrNameRealm string Player name (with or without realm)
-- @param defaultRealm string|nil Optional default realm (uses GetRealmName() if nil)
-- @return string|nil Canonical "Name-Realm" or nil if invalid
--
-- Rules:
-- - Trims leading/trailing whitespace from both name and realm
-- - Strips internal spaces from realm name (e.g., "Area 52" -> "Area52")
-- - Fills missing realm with defaultRealm or GetRealmName()
-- - Returns "Name-Realm" format (name is case-sensitive, realm is normalized)
-- - Returns nil for empty/invalid input
function NameUtil.NormalizeNameRealm(nameOrNameRealm, defaultRealm)
    -- Validate input
    if type(nameOrNameRealm) ~= "string" or nameOrNameRealm == "" then
        return nil
    end
    
    -- Trim whitespace
    nameOrNameRealm = strtrim(nameOrNameRealm)
    if nameOrNameRealm == "" then
        return nil
    end
    
    local name, realm
    
    -- Check if already in "Name-Realm" format
    if nameOrNameRealm:find("-", 1, true) then
        -- Split on first hyphen only (handles names with hyphens)
        local hyphenPos = nameOrNameRealm:find("-", 1, true)
        name = nameOrNameRealm:sub(1, hyphenPos - 1)
        realm = nameOrNameRealm:sub(hyphenPos + 1)
        
        -- Trim both parts
        name = strtrim(name)
        realm = strtrim(realm)
        
        -- Validate split - if either part is empty, return nil (invalid format)
        if name == "" or realm == "" then
            return nil
        end
    else
        -- No hyphen, treat as name-only
        name = nameOrNameRealm
        realm = nil
    end
    
    -- Get realm if not present
    if not realm or realm == "" then
        if type(defaultRealm) == "string" and defaultRealm ~= "" then
            realm = defaultRealm
        else
            realm = GetRealmName()
        end
        
        -- Final realm validation
        if not realm or realm == "" then
            return nil
        end
    end
    
    -- Normalize realm: strip ALL internal spaces
    realm = realm:gsub("%s+", "")
    
    -- Final validation
    if name == "" or realm == "" then
        return nil
    end
    
    return name .. "-" .. realm
end

-- ============================================================================
-- Comparison
-- ============================================================================

--- Compare two player identifiers for equality
-- @param a string First player identifier
-- @param b string Second player identifier
-- @return boolean True if both refer to the same player, false otherwise
--
-- Rules:
-- - Normalizes both inputs before comparison
-- - Case-INsensitive comparison (player names are case-insensitive in WoW)
-- - Returns false if either input is invalid
function NameUtil.SamePlayer(a, b)
    local normA = NameUtil.NormalizeNameRealm(a)
    local normB = NameUtil.NormalizeNameRealm(b)
    
    if not normA or not normB then
        return false
    end
    
    -- Case-insensitive comparison
    return normA:lower() == normB:lower()
end

-- ============================================================================
-- Convenience Helpers
-- ============================================================================

--- Get the current player's canonical identifier
-- @return string|nil Current player's "Name-Realm" or nil if unavailable
function NameUtil.GetSelfId()
    local name, realm = UnitFullName("player")
    if not name or name == "" then
        name = UnitName("player")
    end
    
    if not name or name == "" then
        return nil
    end
    
    return NameUtil.NormalizeNameRealm(name, realm)
end

-- Export to namespace
SF.NameUtil = NameUtil
