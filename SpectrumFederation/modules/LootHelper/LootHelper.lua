-- Grab the namespace
local addonName, SF = ...

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

    -- Restore metatables for profiles/members/logs after SavedVariables load
    if SF.RehydrateLootHelperDB then
        SF:RehydrateLootHelperDB()
    end

    -- Maintain legacy pointer
    SF.lootHelperDB.activeProfile = nil
    if SF.lootHelperDB.activeProfileId then
        SF:SetActiveProfileById(SF.lootHelperDB.activeProfileId)
    end

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
            if not key:match("^p_%x+") and profile.GetProfileId then
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
    
    -- Migrate activeProfile (pointer) to activeProfileId, then restore pointer
    if db.activeProfile and type(db.activeProfile) == "table" and db.activeProfile.GetProfileId then
        local profileId = db.activeProfile:GetProfileId()
        if profileId then
            db.activeProfileId = profileId
            -- Keep pointer for backward compatibility with existing code
            db.activeProfile = newProfiles[profileId]
            if SF.Debug then
                SF.Debug:Info("DATABASE", "Migrated active profile: %s -> %s", 
                    db.activeProfile:GetProfileName() or "Unknown", profileId)
            end
        end
    elseif db.activeProfileId and newProfiles[db.activeProfileId] then
        -- Restore pointer if activeProfileId exists but pointer was nil
        db.activeProfile = newProfiles[db.activeProfileId]
    else
        -- Clear if neither field is valid
        db.activeProfile = nil
        db.activeProfileId = nil
    end
    
    if SF.Debug then SF.Debug:Info("DATABASE", "Schema migration complete: %d profiles", 
        SF:TableSize(newProfiles)) end
end

-- Rehydrate LootHelper database by restoring metatables to instances
-- Called after loading SavedVariables to restore class methods
-- @return: none
function SF:RehydrateLootHelperDB()
	local db = self.lootHelperDB
	if not db or type(db.profiles) ~= "table" then return end

	for id, profile in pairs(db.profiles) do
		if type(profile) == "table" then
			-- Restore LootProfile methods
			if self.LootProfile and getmetatable(profile) ~= self.LootProfile then
				setmetatable(profile, self.LootProfile)
			end

			-- Restore Member methods
			if type(profile._members) == "table" and self.Member then
				for i, m in ipairs(profile._members) do
					if type(m) == "table" and getmetatable(m) ~= self.Member then
						setmetatable(m, self.Member)
					end
				end
			end

			-- Restore LootLog methods
			if type(profile._lootLogs) == "table" and self.LootLog then
				for i, log in ipairs(profile._lootLogs) do
					if type(log) == "table" and getmetatable(log) ~= self.LootLog then
						setmetatable(log, self.LootLog)
					end
				end
			end

			-- Rebuild indexes/counters if available
			if profile.RebuildLogIndex then
				profile:RebuildLogIndex()
			end

			-- Ensure owner is admin if you added that helper
			if profile._EnsureOwnerIsAdmin then
				profile:_EnsureOwnerIsAdmin()
			end
		end
	end
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
        SF.lootHelperDB.activeProfile = nil
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

    -- Update BOTH canonical ID and legacy pointer
    -- TODO: We should probably update code to only use one or the other
    SF.lootHelperDB.activeProfileId = profileId
    SF.lootHelperDB.activeProfile = profile

    if SF.Debug then
        SF.Debug:Info("DATABASE", "Set loot profile '%s' (ID: %s) as active", 
            profile:GetProfileName() or "Unknown", profileId)
    end

    return true
end

-- Clear the active loot profile (used when deleting active profile)
-- @return nil
function SF:ClearActiveProfile()
    -- Deactivate all profiles
    for _, prof in pairs(SF.lootHelperDB.profiles) do
        if prof.SetActive then
            prof:SetActive(false)
        end
    end
    
    -- Clear both fields
    SF.lootHelperDB.activeProfileId = nil
    SF.lootHelperDB.activeProfile = nil
    
    if SF.Debug then
        SF.Debug:Info("DATABASE", "Cleared active profile")
    end
end

-- Get the active loot profile
-- @return (LootProfile|nil) - Active profile instance or nil
function SF:GetActiveProfile()
    return SF.lootHelperDB and SF.lootHelperDB.activeProfile or nil
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

-- Get profile options for dropdown/UI selection
-- @return (table) - Array of { value = profileId, label = profileName }
function SF:GetLootHelperProfileOptions()
	local out = {}
	local db = self.lootHelperDB
	if not db or type(db.profiles) ~= "table" then return out end

	for id, profile in pairs(db.profiles) do
		local name = id
		if type(profile) == "table" then
			if profile.GetProfileName then
				name = profile:GetProfileName()
			elseif profile._profileName then
				name = profile._profileName
			end
		end
		table.insert(out, { value = id, label = tostring(name) })
	end

	table.sort(out, function(a, b)
		return tostring(a.label) < tostring(b.label)
	end)

	return out
end

-- Create a new loot helper profile
-- @param profileName (string) - Name for the new profile
-- @return (boolean, string|nil) - Success status and optional error message
function SF:CreateLootHelperProfile(profileName)
	profileName = tostring(profileName or ""):match("^%s*(.-)%s*$")
	if profileName == "" then return false, "Profile name cannot be empty." end
	if profileName:find("%.") then return false, "Profile name cannot contain '.'." end

	-- Enforce unique name (per your requirement)
	for _, prof in pairs(self.lootHelperDB.profiles or {}) do
		local n = (prof and prof.GetProfileName and prof:GetProfileName()) or (prof and prof._profileName)
		if n == profileName then
			return false, "A profile with that name already exists."
		end
	end

	if not self.LootProfile or not self.LootProfile.new then
		return false, "LootProfile class not loaded."
	end

	local p = self.LootProfile.new(profileName)
	if not p then
		return false, "Failed to create profile."
	end

	local ok = self:AddLootProfileToDatabase(p)
	if not ok then
		return false, "Failed to add profile to database."
	end

	return true
end

-- Delete a loot helper profile by ID
-- @param profileId (string) - Profile ID to delete
-- @return (boolean, string|nil) - Success status and optional error message
function SF:DeleteLootHelperProfile(profileId)
	if type(profileId) ~= "string" or profileId == "" then
		return false, "Invalid profile id."
	end

	local db = self.lootHelperDB
	if not db or not db.profiles or not db.profiles[profileId] then
		return false, "Profile not found."
	end

	db.profiles[profileId] = nil

	-- If we deleted the active profile, pick a new one or nil
	if db.activeProfileId == profileId then
		db.activeProfileId = nil
		db.activeProfile = nil

		-- Pick first sorted option (nice UX, minimal logic)
		local opts = self:GetLootHelperProfileOptions()
		if #opts > 0 then
			self:SetActiveProfileById(opts[1].value)
		end
	end

	return true
end

-- Rename the active loot helper profile
-- @param newName (string) - New name for the profile
-- @return (boolean, string|nil) - Success status and optional error message
function SF:RenameActiveLootHelperProfile(newName)
	local p = self:GetActiveProfile()
	if not p then return false, "No active profile." end

	newName = tostring(newName or ""):match("^%s*(.-)%s*$")
	if newName == "" then return false, "Profile name cannot be empty." end
	if newName:find("%.") then return false, "Profile name cannot contain '.'." end

	-- Unique name enforcement
	for _, prof in pairs(self.lootHelperDB.profiles or {}) do
		if prof ~= p then
			local n = (prof and prof.GetProfileName and prof:GetProfileName()) or (prof and prof._profileName)
			if n == newName then
				return false, "A profile with that name already exists."
			end
		end
	end

	if p.SetProfileName then
		p:SetProfileName(newName)
		return true
	end

	return false, "Active profile cannot be renamed (missing SetProfileName)."
end

-- Add an admin to the active loot helper profile
-- @param memberId (string) - Member ID to add as admin
-- @return (boolean, string|nil) - Success status and optional error message
function SF:AddAdminToActiveLootHelperProfile(memberId)
	local p = self:GetActiveProfile()
	if not p then return false, "No active profile." end
	if not p.AddAdminMemberId then return false, "Profile missing AddAdminMemberId." end
	return p:AddAdminMemberId(memberId)
end

-- Remove an admin from the active loot helper profile
-- @param memberId (string) - Member ID to remove from admins
-- @return (boolean, string|nil) - Success status and optional error message
function SF:RemoveAdminFromActiveLootHelperProfile(memberId)
	local p = self:GetActiveProfile()
	if not p then return false, "No active profile." end
	if not p.RemoveAdminMemberId then return false, "Profile missing RemoveAdminMemberId." end
	return p:RemoveAdminMemberId(memberId)
end

-- Reset all loot helper settings (dangerous operation)
-- @return (boolean, string|nil) - Success status and optional error message
function SF:ResetAllLootHelperSettings()
	local db = self.lootHelperDB
	if not db then return false, "LootHelper DB not initialized." end

	db.profiles = {}
	db.activeProfileId = nil
	db.activeProfile = nil

	return true
end