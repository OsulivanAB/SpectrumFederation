-- Grab the namespace
local addonName, SF = ...

-- WoW Class Information Dictionary
-- Contains color codes (RGB 0-1 range) and texture file paths for all 13 WoW classes
SF.WOW_CLASSES = {
    WARRIOR = {
        colorCode = {r = 0.78, g = 0.61, b = 0.43},
        textureFile = "Interface\\Icons\\ClassIcon_Warrior"
    },
    PALADIN = {
        colorCode = {r = 0.96, g = 0.55, b = 0.73},
        textureFile = "Interface\\Icons\\ClassIcon_Paladin"
    },
    HUNTER = {
        colorCode = {r = 0.67, g = 0.83, b = 0.45},
        textureFile = "Interface\\Icons\\ClassIcon_Hunter"
    },
    ROGUE = {
        colorCode = {r = 1.00, g = 0.96, b = 0.41},
        textureFile = "Interface\\Icons\\ClassIcon_Rogue"
    },
    PRIEST = {
        colorCode = {r = 1.00, g = 1.00, b = 1.00},
        textureFile = "Interface\\Icons\\ClassIcon_Priest"
    },
    DEATHKNIGHT = {
        colorCode = {r = 0.77, g = 0.12, b = 0.23},
        textureFile = "Interface\\Icons\\ClassIcon_DeathKnight"
    },
    SHAMAN = {
        colorCode = {r = 0.00, g = 0.44, b = 0.87},
        textureFile = "Interface\\Icons\\ClassIcon_Shaman"
    },
    MAGE = {
        colorCode = {r = 0.25, g = 0.78, b = 0.92},
        textureFile = "Interface\\Icons\\ClassIcon_Mage"
    },
    WARLOCK = {
        colorCode = {r = 0.53, g = 0.53, b = 0.93},
        textureFile = "Interface\\Icons\\ClassIcon_Warlock"
    },
    MONK = {
        colorCode = {r = 0.00, g = 1.00, b = 0.59},
        textureFile = "Interface\\Icons\\ClassIcon_Monk"
    },
    DRUID = {
        colorCode = {r = 1.00, g = 0.49, b = 0.04},
        textureFile = "Interface\\Icons\\ClassIcon_Druid"
    },
    DEMONHUNTER = {
        colorCode = {r = 0.64, g = 0.19, b = 0.79},
        textureFile = "Interface\\Icons\\ClassIcon_DemonHunter"
    },
    EVOKER = {
        colorCode = {r = 0.20, g = 0.58, b = 0.50},
        textureFile = "Interface\\Icons\\ClassIcon_Evoker"
    }
}

-- Get current player's name and realm
-- @return: playerName (string), realmName (string)
function SF:GetPlayerInfo()
    local name = UnitName("player")
    local realm = GetRealmName()
    if realm then realm = realm:gsub("%s+", "") end -- Remove spaces from realm name
    if SF.Debug then SF.Debug:Verbose("PROFILES", "Retrieved player info: %s-%s", name, realm) end
    return name, realm
end

-- Get current player's full identifier in "Name-Realm" format
-- @return: string - The player's full identifier (e.g., "Shadowbane-Garona")
function SF:GetPlayerFullIdentifier()
	if SF.NameUtil and SF.NameUtil.GetSelfId then
		return SF.NameUtil.GetSelfId()
	end
	-- Fallback for early initialization
	local name, realm = SF:GetPlayerInfo()
	return name .. "-" .. realm
end

-- Get the current player's class in uppercase (e.g., "WARRIOR")
-- @return: string - The player's class in uppercase
function SF:GetPlayerClass()
    local _, class = UnitClass("player")
    return string.upper(class)
end

-- Database Initialization
function SF:InitializeLootDatabase()

    -- Initialize main database table if it doesn't exist
    if not SpectrumFederationDB then
        SpectrumFederationDB = {}
        if SF.Debug then SF.Debug:Info("DATABASE", "Initialized main SpectrumFederationDB database") end
    else
        if SF.Debug then SF.Debug:Info("DATABASE", "Loaded existing SpectrumFederationDB database") end
    end

    SF.DB = SpectrumFederationDB

    -- Initialize Loot Helper Database
    if SF.InitializeLootHelperDatabase then
        SF:InitializeLootHelperDatabase()
    else
        if SF.Debug then SF.Debug:Warn("DATABASE", "InitializeLootHelperDatabase function not found") end
    end
end

-- Get the user's timezone offset from UTC in seconds
-- @return (number) - Offset in seconds (positive = east of UTC, negative = west)
function SF:GetUserTimezoneOffset()
    return time() - GetServerTime()
end

-- Format UTC timestamp for display in user's local timezone
-- @param utcTimestamp (number) - UTC Unix timestamp from GetServerTime()
-- @return (string) - Formatted timestamp in user's local time (YYYY-MM-DD HH:MM:SS) or error message
function SF:FormatTimestampForUser(utcTimestamp)
    -- Validate timestamp
    if type(utcTimestamp) ~= "number" then
        return "Invalid timestamp"
    end
    
    local userOffset = SF:GetUserTimezoneOffset()
    return date("%Y-%m-%d %H:%M:%S", utcTimestamp + userOffset)
end

-- Format UTC timestamp for display in server's local timezone
-- @param utcTimestamp (number) - UTC Unix timestamp from GetServerTime()
-- @return (string) - Formatted timestamp in server's local time (YYYY-MM-DD HH:MM:SS) or error message
function SF:FormatTimestampForServer(utcTimestamp)
    -- Validate timestamp
    if type(utcTimestamp) ~= "number" then
        return "Invalid timestamp"
    end
    
    local serverLocal = C_DateAndTime.GetServerTimeLocal()
    local serverOffset = serverLocal - GetServerTime()
    return date("%Y-%m-%d %H:%M:%S", utcTimestamp + serverOffset)
end

-- Function Return a current epoch time in seconds.
-- @param none
-- @return number epochSeconds
function SF:Now()
    return (GetServerTime and GetServerTime()) or time()
end

-- Get the addon's current version from metadata
-- @return string version Addon version or "Unknown" if not found
function SF:GetAddonVersion()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata(addonName, "Version") or "Unknown"
    end
    if GetAddOnMetadata then
        return GetAddOnMetadata(addonName, "Version") or "Unknown"
    end
    return "Unknown"
end