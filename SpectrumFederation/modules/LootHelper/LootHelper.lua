-- Grab the namespace
local addonName, SF = ...

-- Database Initialization for Loot Helper Module
-- @return: none
function SF:InitializeLootHelperDatabase()
    -- Initialize loot helper settings in main database if not present
    if not SpectrumFederationDB.lootHelper then
        SpectrumFederationDB.lootHelper = {
            -- Table of loot profile objects
            profiles = {},
            activeProfile = nil     -- Pointer to the active profile object
        }
        if SF.Debug then SF.Debug:Info("DATABASE", "Initialized loot helper settings in main database") end
    else
        if SF.Debug then SF.Debug:Info("DATABASE", "Loaded existing loot helper settings from main database") end
    end

    SF.lootHelperDB = SpectrumFederationDB.lootHelper

    -- Initialize Loot Helper Communications
    if SF.LootHelperComm then
        SF.LootHelperComm:Init()
    end
end

-- function to set the active loot profile
-- @param profileName (string) - Name of the profile to set as active
-- @return (boolean) - true if set successfully, false otherwise
function SF:SetActiveLootProfile(profileName)
    local targetProfile = nil

    -- Find the profile by name. If not found then log with debugger and return false
    for _, profile in ipairs(SF.lootHelperDB.profiles) do
        if profile:GetProfileName() == profileName then
            targetProfile = profile
            break
        end
    end
    if not targetProfile then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "No loot profile found with name '%s' to set as active", profileName)
        end
        return false
    end

    -- Set all profiles to inactive first
    for _, profile in ipairs(SF.lootHelperDB.profiles) do
        profile:SetActive(false)
    end
    
    -- Set target profile as active
    targetProfile:SetActive(true)

    if SF.Debug then
        SF.Debug:Info("DATABASE", "Set loot profile '%s' as active", profileName)
    end
    
    -- Update pointer in database
    SF.lootHelperDB.activeProfile = targetProfile

    return true
end

-- function to add a loot profile to the profiles database
-- @param lootProfile (LootProfile) - Instance of LootProfile to add
-- @return (boolean) - true if added successfully, false otherwise
function SF:AddLootProfileToDatabase(lootProfile)

    if getmetatable(lootProfile) == SF.LootProfile then

        -- Verify there isn't another profile with the same name
        for _, profile in ipairs(SF.lootHelperDB.profiles) do
            if profile:GetProfileName() == lootProfile:GetProfileName() then
                if SF.Debug then
                    SF.Debug:Warn("DATABASE", "Loot profile with name '%s' already exists in database", lootProfile:GetProfileName())
                end
                return false
            end
        end

        table.insert(SF.lootHelperDB.profiles, lootProfile)
        if SF.Debug then
            SF.Debug:Info("DATABASE", "Added loot profile '%s' to database", lootProfile.profileName)
        end

        -- Set new profile as active
        local success = self:SetActiveLootProfile(lootProfile.profileName)

        return success
    else
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "Attempted to add invalid LootProfile instance: %s", tostring(lootProfile))
        end
        return false
    end
end