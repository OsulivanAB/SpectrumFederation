-- Grab the namespace
local addonName, SF = ...

-- Canonical Schema (profileId-based):
--
-- SF.lootHelperDB = {
--     profiles = {},              -- Map: [profileId] -> LootProfile instance
--     activeProfileId = nil,      -- String: currently active profileId (not profileName)
-- }
--
-- Why profileId as key:
-- - Profiles can be renamed without breaking references
-- - Sync system already uses profileId as stable identifier
-- - Multi-writer scenarios need collision-free keys
-- - Eliminates name-based lookup ambiguity

-- Database Initialization for Loot Helper Module
-- @return: none
function SF:InitializeLootHelperDatabase()
    -- Initialize loot helper settings in main database if not present
    if not SpectrumFederationDB.lootHelper then
        SpectrumFederationDB.lootHelper = {
            profiles = {},              -- Map: profileId -> LootProfile
            activeProfileId = nil       -- Active profile's stable ID
        }
        if SF.Debug then SF.Debug:Info("DATABASE", "Initialized loot helper database with profileId-based schema") end
    else
        if SF.Debug then SF.Debug:Info("DATABASE", "Loaded existing loot helper database") end
        
        -- Migration: Detect and convert legacy schema (no-op if already clean)
        SF:MigrateLootHelperSchema()
    end

    SF.lootHelperDB = SpectrumFederationDB.lootHelper

    -- Initialize Loot Helper Communications
    if SF.LootHelperComm then
        SF.LootHelperComm:Init()
    end
end

-- Migrate legacy schema to profileId-based canonical schema
-- Handles legacy patterns from development:
-- 1. Array-style: profiles[1], profiles[2], ...
-- 2. Map-by-name: profiles["ProfileName"]
-- 3. Mixed: Both array and map entries
--
-- This is a one-time migration for development data only.
-- @return: none
function SF:MigrateLootHelperSchema()
    local db = SpectrumFederationDB.lootHelper
    if not db or not db.profiles then return end
    
    -- Detect if migration is needed
    local needsMigration = false
    local legacyProfiles = {}
    
    -- Check for array-style storage (numeric keys)
    for i, profile in ipairs(db.profiles) do
        if type(profile) == "table" and profile.GetProfileId then
            needsMigration = true
            table.insert(legacyProfiles, profile)
        end
    end
    
    -- Check for map-by-name storage (string keys that aren't profileIds)
    for key, profile in pairs(db.profiles) do
        if type(key) == "string" and type(profile) == "table" then
            -- ProfileId format: "p_" prefix + hex digits
            if not key:match("^p_%%x+") and profile.GetProfileId then
                needsMigration = true
                table.insert(legacyProfiles, profile)
            end
        end
    end
    
    if not needsMigration then
        if SF.Debug then SF.Debug:Verbose("DATABASE", "Schema is already up-to-date") end
        return
    end
    
    if SF.Debug then SF.Debug:Info("DATABASE", "Migrating loot helper schema to profileId-based storage") end
    
    -- Build new map keyed by profileId
    local newProfiles = {}
    for _, profile in ipairs(legacyProfiles) do
        local profileId = profile:GetProfileId()
        if profileId then
            newProfiles[profileId] = profile
            if SF.Debug then
                SF.Debug:Verbose("DATABASE", "Migrated profile: %s (ID: %s)", 
                    profile:GetProfileName() or "Unknown", profileId)
            end
        else
            if SF.Debug then
                SF.Debug:Warn("DATABASE", "Skipping profile without profileId: %s", 
                    tostring(profile:GetProfileName()))
            end
        end
    end
    
    -- Replace old profiles table with new map
    db.profiles = newProfiles
    
    -- Migrate activeProfile (pointer) to activeProfileId
    if db.activeProfile and type(db.activeProfile) == "table" and db.activeProfile.GetProfileId then
        local profileId = db.activeProfile:GetProfileId()
        if profileId then
            db.activeProfileId = profileId
            if SF.Debug then
                SF.Debug:Info("DATABASE", "Migrated active profile: %s -> %s", 
                    db.activeProfile:GetProfileName() or "Unknown", profileId)
            end
        end
        db.activeProfile = nil  -- Clear legacy field
    end
    
    if SF.Debug then SF.Debug:Info("DATABASE", "Schema migration complete: %d profiles", 
        SF:TableSize(newProfiles)) end
end

-- Helper: Count entries in a table (works for maps and arrays)
-- @param t table Table to count
-- @return number Count of entries
function SF:TableSize(t)
    if not t or type(t) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Set the active loot profile by profileId (canonical method)
-- @param profileId (string) - Stable ID of the profile to set as active
-- @return (boolean) - true if set successfully, false otherwise
function SF:SetActiveProfileById(profileId)
    if type(profileId) ~= "string" or profileId == "" then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "SetActiveProfileById called with invalid profileId: %s", tostring(profileId))
        end
        return false
    end

    local profile = SF.lootHelperDB.profiles[profileId]
    if not profile then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "No loot profile found with ID '%s' to set as active", profileId)
        end
        return false
    end

    -- Deactivate all profiles first
    for _, prof in pairs(SF.lootHelperDB.profiles) do
        if prof.SetActive then
            prof:SetActive(false)
        end
    end
    
    -- Set target profile as active
    if profile.SetActive then
        profile:SetActive(true)
    end

    -- Update pointer in database
    SF.lootHelperDB.activeProfileId = profileId

    if SF.Debug then
        SF.Debug:Info("DATABASE", "Set loot profile '%s' (ID: %s) as active", 
            profile:GetProfileName() or "Unknown", profileId)
    end

    return true
end

-- Get the active loot profile
-- @return (LootProfile|nil) - Active profile instance or nil
function SF:GetActiveProfile()
    local profileId = SF.lootHelperDB.activeProfileId
    if not profileId then return nil end
    
    return SF.lootHelperDB.profiles[profileId]
end

-- Legacy function to set the active loot profile by name
-- DEPRECATED: Use SetActiveProfileById instead (kept for transition period)
-- @param profileName (string) - Name of the profile to set as active
-- @return (boolean) - true if set successfully, false otherwise
function SF:SetActiveLootProfile(profileName)
    if SF.Debug then
        SF.Debug:Warn("DATABASE", "SetActiveLootProfile (name-based) is deprecated, use SetActiveProfileById")
    end

    -- Find profile by name
    for profileId, profile in pairs(SF.lootHelperDB.profiles) do
        if profile:GetProfileName() == profileName then
            return SF:SetActiveProfileById(profileId)
        end
    end

    if SF.Debug then
        SF.Debug:Warn("DATABASE", "No loot profile found with name '%s' to set as active", profileName)
    end
    return false
end

-- function to add a loot profile to the profiles database
-- @param lootProfile (LootProfile) - Instance of LootProfile to add
-- @return (boolean) - true if added successfully, false otherwise
function SF:AddLootProfileToDatabase(lootProfile)

    if getmetatable(lootProfile) ~= SF.LootProfile then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "Attempted to add invalid LootProfile instance: %s", tostring(lootProfile))
        end
        return false
    end

    local profileId = lootProfile:GetProfileId()
    if not profileId then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "Cannot add profile without profileId")
        end
        return false
    end

    -- Check if profile already exists
    if SF.lootHelperDB.profiles[profileId] then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "Loot profile with ID '%s' already exists in database", profileId)
        end
        return false
    end

    SF.lootHelperDB.profiles[profileId] = lootProfile
    if SF.Debug then
        SF.Debug:Info("DATABASE", "Added loot profile '%s' (ID: %s) to database", 
            lootProfile:GetProfileName(), profileId)
    end

    -- Set new profile as active
    local success = self:SetActiveProfileById(profileId)

    return success
end