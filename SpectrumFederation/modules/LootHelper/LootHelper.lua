-- Grab the namespace
local addonName, SF = ...

-- Database Initialization for Loot Helper Module
-- @return: none
function SF:InitializeLootHelperDatabase()
    -- Initialize loot helper settings in main database if not present
    if not SpectrumFederationDB.lootHelper then
        SpectrumFederationDB.lootHelper = {
			enabled = false,
			showWindowOutsideRaid = false,
			lockLootWindow = false,
			showMembersNotInRaid = false,

			window = {},

            profiles = {},              -- Map: profileId -> LootProfile
            activeProfileId = nil       -- Active profile's stable ID
        }
        if SF.Debug then SF.Debug:Info("DATABASE", "Initialized loot helper database with profileId-based schema") end
    else
        if SF.Debug then SF.Debug:Info("DATABASE", "Loaded existing loot helper database") end
        
        -- Migration: Detect and convert legacy schema (no-op if already clean)
        SF:MigrateLootHelperSchema()

		local lh = SpectrumFederationDB.lootHelper
		if lh.enabled == nil then lh.enabled = false end
		if lh.showWindowOutsideRaid == nil then lh.showWindowOutsideRaid = false end
		if lh.lockLootWindow == nil then lh.lockLootWindow = false end
		if lh.showMembersNotInRaid == nil then lh.showMembersNotInRaid = false end

		if type(lh.window) ~= "table" then
			lh.window = {}
		end
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

	-- Loot Helper Window
	if SF.LootHelperWindow and SF.LootHelperWindow.Controller and SF.LootHelperWindow.Controller.Init then
		SF.LootHelperWindow.Controller:Init()
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
	if not db or type(db.profiles) ~= "table" then
		if SF.Debug then
			SF.Debug:Verbose("DATABASE", "RehydrateLootHelperDB: No profiles to rehydrate")
		end
		return
	end

	local profileCount = 0
	local memberCount = 0
	local logCount = 0

	for id, profile in pairs(db.profiles) do
		if type(profile) == "table" then
			profileCount = profileCount + 1

			-- Restore LootProfile methods
			if self.LootProfile and getmetatable(profile) ~= self.LootProfile then
				setmetatable(profile, self.LootProfile)
			end

			if type(profile._EnsureRaidCheckConfig) == "function" then
				profile:_EnsureRaidCheckConfig()
			end

			-- Restore Member methods
			if type(profile._members) == "table" and self.Member then
				-- Helper function to extract member ID for deduplication
				-- Returns nil if no valid identifier found (member will be skipped)
				local function GetMemberId(m)
					if type(m.identifier) == "string" and m.identifier ~= "" then
						return m.identifier
					elseif type(m._identifier) == "string" and m._identifier ~= "" then
						return m._identifier
					else
						-- No valid identifier - log warning with member details
						if SF.Debug then
							SF.Debug:Warn("DATABASE", "Member has no valid identifier, skipping (type=%s, has_identifier=%s, has__identifier=%s)",
								type(m), tostring(m.identifier ~= nil), tostring(m._identifier ~= nil))
						end
						return nil
					end
				end
				
				-- Debug: check what type of structure _members is
				local arrayCount = #profile._members
				local totalKeys = 0
				for _ in pairs(profile._members) do
					totalKeys = totalKeys + 1
				end
				
				if SF.Debug and totalKeys > 0 then
					SF.Debug:Verbose("DATABASE", "Profile %s _members structure: arrayLen=%d, totalKeys=%d",
						tostring(profile._profileName or profile._profileId), arrayCount, totalKeys)
				end
				
				-- Try array iteration first (normal case)
				local arrayProcessed = {}
				for i, m in ipairs(profile._members) do
					if type(m) == "table" then
						if getmetatable(m) ~= self.Member then
							setmetatable(m, self.Member)
							memberCount = memberCount + 1
						end
						-- Track which members were found in array (using member ID)
						local memberId = GetMemberId(m)
						if memberId then
							arrayProcessed[memberId] = true
							if SF.Debug then
								SF.Debug:Verbose("DATABASE", "Array member[%d]: %s", i, memberId)
							end
						end
					end
				end
				
				if SF.Debug and memberCount > 0 then
					SF.Debug:Info("DATABASE", "Processed %d members via array iteration (ipairs)", memberCount)
				end
				
				-- Fallback: if we found fewer members via ipairs than total keys, there are map entries
				-- This handles legacy data that might have been stored as a map
				if memberCount < totalKeys then
					if SF.Debug then
						SF.Debug:Warn("DATABASE", "Profile %s has members stored as map (not array), migrating...",
							tostring(profile._profileName or profile._profileId))
						SF.Debug:Warn("DATABASE", "Migration triggered: arrayCount=%d, memberCount=%d, totalKeys=%d",
							arrayCount, memberCount, totalKeys)
					end
					
					-- Build array from all entries using pairs (includes both array and map entries)
					local memberArray = {}
					local processed = {}
					local mapOnlyCount = 0
					
					-- Process all entries (both array indices and string keys)
					for k, m in pairs(profile._members) do
						if type(m) == "table" then
							local memberId = GetMemberId(m)
							
							-- Only process if we have a valid ID and haven't seen this member yet
							if memberId and not processed[memberId] then
								if getmetatable(m) ~= self.Member then
									setmetatable(m, self.Member)
								end
								table.insert(memberArray, m)
								processed[memberId] = true
								
								-- Track whether this is a new map-only member
								local isMapOnly = not arrayProcessed[memberId]
								if isMapOnly then
									memberCount = memberCount + 1
									mapOnlyCount = mapOnlyCount + 1
									if SF.Debug then
										SF.Debug:Info("DATABASE", "Map-only member found (key=%s): %s", tostring(k), memberId)
									end
								end
							elseif not memberId then
								if SF.Debug then
									SF.Debug:Warn("DATABASE", "Skipping member with invalid ID at key: %s", tostring(k))
								end
							else
								if SF.Debug then
									SF.Debug:Verbose("DATABASE", "Duplicate member skipped (key=%s): %s", tostring(k), memberId)
								end
							end
						end
					end
					
					-- Replace with cleaned array
					profile._members = memberArray
					
					if SF.Debug then
						SF.Debug:Info("DATABASE", "Migration complete: %d total members (%d from array, %d from map-only)",
							#memberArray, memberCount - mapOnlyCount, mapOnlyCount)
					end
				end
			end

			-- Restore LootLog methods
			if type(profile._lootLogs) == "table" and self.LootLog then
				for i, log in ipairs(profile._lootLogs) do
					if type(log) == "table" and getmetatable(log) ~= self.LootLog then
						setmetatable(log, self.LootLog)
						logCount = logCount + 1
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

	if SF.Debug then
		SF.Debug:Info("DATABASE", "Rehydrated %d profiles, %d members, %d logs", profileCount, memberCount, logCount)
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
			if SF.Debug then
				SF.Debug:Warn("DATABASE", "Cannot create profile - name already exists: %s", profileName)
			end
			return false, "A profile with that name already exists."
		end
	end

	if not self.LootProfile or not self.LootProfile.new then
		if SF.Debug then
			SF.Debug:Error("DATABASE", "LootProfile class not loaded")
		end
		return false, "LootProfile class not loaded."
	end

	local p = self.LootProfile.new(profileName)
	if not p then
		if SF.Debug then
			SF.Debug:Error("DATABASE", "Failed to create profile instance for: %s", profileName)
		end
		return false, "Failed to create profile."
	end

	local ok = self:AddLootProfileToDatabase(p)
	if not ok then
		if SF.Debug then
			SF.Debug:Error("DATABASE", "Failed to add profile to database: %s", profileName)
		end
		return false, "Failed to add profile to database."
	end

	if SF.Debug then
		SF.Debug:Info("DATABASE", "Created new profile: %s (ID: %s)", profileName, p:GetProfileId())
	end

	return true
end

-- Delete a loot helper profile by ID
-- @param profileId (string) - Profile ID to delete
-- @return (boolean, string|nil) - Success status and optional error message
function SF:DeleteLootHelperProfile(profileId)
	if type(profileId) ~= "string" or profileId == "" then
		if SF.Debug then
			SF.Debug:Warn("DATABASE", "Cannot delete profile - invalid profileId: %s", tostring(profileId))
		end
		return false, "Invalid profile id."
	end

	local db = self.lootHelperDB
	if not db or not db.profiles or not db.profiles[profileId] then
		if SF.Debug then
			SF.Debug:Warn("DATABASE", "Cannot delete profile - not found: %s", profileId)
		end
		return false, "Profile not found."
	end

	local profileName = db.profiles[profileId]:GetProfileName()
	db.profiles[profileId] = nil

	if SF.Debug then
		SF.Debug:Info("DATABASE", "Deleted profile: %s (ID: %s)", profileName or "Unknown", profileId)
	end

	-- If we deleted the active profile, pick a new one or nil
	if db.activeProfileId == profileId then
		self:ClearActiveProfile()

		-- Pick first sorted option (nice UX, minimal logic)
		local opts = self:GetLootHelperProfileOptions()
		if #opts > 0 then
			self:SetActiveProfileById(opts[1].value)
			if SF.Debug then
				SF.Debug:Info("DATABASE", "Auto-selected new active profile: %s", opts[1].label)
			end
		else
			if SF.Debug then
				SF.Debug:Info("DATABASE", "No profiles remaining after deletion")
			end
		end
	end

	return true
end

-- Rename the active loot helper profile
-- @param newName (string) - New name for the profile
-- @return (boolean, string|nil) - Success status and optional error message
function SF:RenameActiveLootHelperProfile(newName)
	local p = self:GetActiveProfile()
	if not p then
		if SF.Debug then
			SF.Debug:Warn("DATABASE", "Cannot rename - no active profile")
		end
		return false, "No active profile."
	end

	local oldName = p:GetProfileName()
	newName = tostring(newName or ""):match("^%s*(.-)%s*$")
	if newName == "" then return false, "Profile name cannot be empty." end
	if newName:find("%.") then return false, "Profile name cannot contain '.'." end

	-- Unique name enforcement
	for _, prof in pairs(self.lootHelperDB.profiles or {}) do
		if prof ~= p then
			local n = (prof and prof.GetProfileName and prof:GetProfileName()) or (prof and prof._profileName)
			if n == newName then
				if SF.Debug then
					SF.Debug:Warn("DATABASE", "Cannot rename - name already exists: %s", newName)
				end
				return false, "A profile with that name already exists."
			end
		end
	end

	if p.SetProfileName then
		p:SetProfileName(newName)
		
		if SF.Debug then
			SF.Debug:Info("DATABASE", "Renamed profile: %s -> %s (ID: %s)", oldName, newName, p:GetProfileId())
		end
		return true
	end

	if SF.Debug then
		SF.Debug:Error("DATABASE", "Cannot rename - profile missing SetProfileName method")
	end
	return false, "Active profile cannot be renamed (missing SetProfileName)."
end

-- Add an admin to the active loot helper profile
-- @param memberId (string) - Member ID to add as admin
-- @return (boolean, string|nil) - Success status and optional error message
function SF:AddAdminToActiveLootHelperProfile(memberId)
	if SF.Debug then
		SF.Debug:Info("LOOTHELPER", "AddAdminToActiveLootHelperProfile called with memberId: %s", tostring(memberId))
	end
	
	local p = self:GetActiveProfile()
	if not p then 
		if SF.Debug then
			SF.Debug:Warn("LOOTHELPER", "No active profile")
		end
		return false, "No active profile." 
	end
	
	if not p.AddAdminMemberId then 
		if SF.Debug then
			SF.Debug:Warn("LOOTHELPER", "Profile missing AddAdminMemberId method")
		end
		return false, "Profile missing AddAdminMemberId." 
	end
	
	local ok, err = p:AddAdminMemberId(memberId)
	if SF.Debug then
		SF.Debug:Info("LOOTHELPER", "AddAdminMemberId returned: ok=%s, err=%s", tostring(ok), tostring(err))
	end
	return ok, err
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
	if not db then
		if SF.Debug then
			SF.Debug:Error("DATABASE", "Cannot reset - LootHelper DB not initialized")
		end
		return false, "LootHelper DB not initialized."
	end

	local profileCount = 0
	for _ in pairs(db.profiles or {}) do
		profileCount = profileCount + 1
	end

	db.profiles = {}
	db.activeProfileId = nil
	db.activeProfile = nil

	if SF.Debug then
		SF.Debug:Info("DATABASE", "Reset all loot helper settings - cleared %d profiles", profileCount)
	end

	return true
end
