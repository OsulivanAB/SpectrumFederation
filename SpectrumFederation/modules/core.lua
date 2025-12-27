-- Grab the namespace
local addonName, SF = ...

-- Get current player's name and realm
-- @return: playerName (string), realmName (string)
function SF:GetPlayerInfo()
    local name = UnitName("player")
    local realm = GetRealmName()
    if SF.Debug then SF.Debug:Verbose("PROFILES", "Retrieved player info: %s-%s", name, realm) end
    return name, realm
end

-- Get current player's full identifier in "Name-Realm" format
-- @return: string - The player's full identifier (e.g., "Shadowbane-Garona")
function SF:GetPlayerFullIdentifier()
    local name, realm = SF:GetPlayerInfo()
    return name .. "-" .. realm
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