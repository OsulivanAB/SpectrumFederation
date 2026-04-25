-- Grab the namespace
local addonName, SF = ...

SF.SettingsStore = SF.SettingsStore or {}
local Store = SF.SettingsStore

-- Create a deep copy of a table recursively
-- @param src table|any The value to copy
-- @return table|any A deep copy of the input (non-tables are returned as-is)
local function DeepCopy(src)
	if type(src) ~= "table" then return src end
	local dst = {}
	for k, v in pairs(src) do
		dst[k] = DeepCopy(v)
	end
	return dst
end

-- Recursively merge default values into a table without overwriting existing values
-- @param dst table Destination table to merge defaults into
-- @param defaults table Table containing default values
-- @return nil
local function MergeDefaults(dst, defaults)
	for k, v in pairs(defaults) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then
				dst[k] = {}
			end
			MergeDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

-- Split a dot-path string into individual path components
-- @param path string Path like "foo.bar.baz" to split
-- @return table Array of path components
local function SplitPath(path)
	local parts = {}
	for part in string.gmatch(path, "[^%.]+") do
		table.insert(parts, part)
	end
	return parts
end

-- Traverse nested table using dot-path notation and return container and final key
-- @param root table Root table to start traversal from
-- @param path string Dot-path like "foo.bar.baz"
-- @param createMissing boolean If true, create missing intermediate tables
-- @return table|nil Parent table, string Final key component, or nil if path invalid
local function ResolvePath(root, path, createMissing)
	local parts = SplitPath(path)
	local t = root

	for i = 1, #parts - 1 do
		local key = parts[i]
		local nextVal = t[key]

		if nextVal == nil then
			if not createMissing then return nil end
			nextVal = {}
			t[key] = nextVal
		end

		if type(nextVal) ~= "table" then
			if not createMissing then return nil end
			nextVal = {}
			t[key] = nextVal
		end

		t = nextVal
	end

	return t, parts[#parts]
end

-- Trim whitespace from both ends of a string
-- @param s string|nil String to trim
-- @return string Trimmed string, or empty string if input is nil
local function Trim(s)
	return (s or ""):match("^%s*(.-)%s*$")
end

-- Validate a profile name for safety and length
-- @param name string The profile name to validate
-- @return boolean True if valid, false otherwise
-- @return string|nil Error message if invalid
local function IsValidProfileName(name)
	name = Trim(name)
	if name == "" then
		return false, "Profile name cannot be empty."
	end
	-- Keep it simple/safe (prevents weird keys & avoids dot-path ambiguity)
	if name:find("%.") then
		return false, "Profile name cannot contain '.'"
	end
	if #name > 24 then
		return false, "Profile name is too long (max 24 chars)."
	end
	return true
end

-- ----------------------------
-- Init / DB
-- ----------------------------

-- Run schema migrations to upgrade database from current version to target version
-- @param schema table Schema definition with VERSION and MIGRATIONS tables
-- @return nil
-- Update SettingsStore to current version
function Store:_RunMigrations(schema)
	local migrations = (schema and schema.MIGRATIONS) or {}
	local target = (schema and schema.VERSION) or 1

	local current = tonumber(self.db.version) or 1
	if SF.Debug then
		SF.Debug:Info("SETTINGS", "Running migrations from v%d to v%d", current, target)
	end

	while current < target do
		local nextVersion = current + 1
		local fn = migrations[nextVersion]

		if type(fn) == "function" then
			if SF.Debug then
				SF.Debug:Verbose("SETTINGS", "Executing migration to v%d", nextVersion)
			end
			local ok, err = pcall(fn, self.db)
			if not ok then
				if SF.Debug then
					SF.Debug:Error("SETTINGS", "Migration to v%d failed: %s", nextVersion, tostring(err))
				end
				return
			end
			if SF.Debug then
				SF.Debug:Info("SETTINGS", "Successfully migrated to v%d", nextVersion)
			end
		end

		current = nextVersion
		self.db.version = current
	end
end

function Store:Init()
	if SF.Debug then
		SF.Debug:Info("SETTINGS", "Initializing SettingsStore")
	end

	local schema = SF.SettingsSchema
	local defaults = (schema and schema.DEFAULTS) or {}
	local characterDefaults = (schema and schema.CHARACTER_DEFAULTS) or {}

	SpectrumFederationDB = SpectrumFederationDB or {}
	self.db = SpectrumFederationDB

	SpectrumFederationCharDB = SpectrumFederationCharDB or {}
	self.charDb = SpectrumFederationCharDB

	local targetVersion = (schema and schema.VERSION) or 1

	-- If version is missing, infer:
	-- - If DB already has keys, assume it's old v1 ("pre-versioning")
	-- - If DB is empty, treat as fresh install at the latest schema
	if tonumber(self.db.version) == nil then
		if next(self.db) ~= nil then
			if SF.Debug then
				SF.Debug:Info("SETTINGS", "Existing database found, assuming v1")
			end
			self.db.version = 1
		else
			if SF.Debug then
				SF.Debug:Info("SETTINGS", "Fresh database, setting to v%d", targetVersion)
			end
			self.db.version = targetVersion			
		end		
	end

	-- Run migrations
	if tonumber(self.db.version) < targetVersion then
		self:_RunMigrations(schema)
	end

	-- Apply defaults without overwriting player values
	MergeDefaults(self.db, DeepCopy(defaults))
	MergeDefaults(self.charDb, DeepCopy(characterDefaults))

	-- Future: migrations
	self.db.version = self.db.version or (schema and schema.VERSION) or 1

	self:_EnsureLootHelper()

	-- Stamp final version
	self.db.version = math.max(tonumber(self.db.version) or 1, targetVersion)

	if SF.Debug then
		SF.Debug:Info("SETTINGS", "SettingsStore initialized at v%d", self.db.version)
	end
end

-- ----------------------------
-- Get/Set + callbacks
-- ----------------------------

-- Retrieve a setting value by dot-path notation
-- @param path string Dot-path like "global.fontSize" or "lootHelper.enabled"
-- @return any Setting value, or nil if path does not exist
function Store:Get(path)
	local parent, key = ResolvePath(self.db, path, false)
	if not parent then return nil end
	return parent[key]
end

-- Set a setting value by dot-path notation and trigger callbacks
-- @param path string Dot-path like "global.fontSize"
-- @param value any The value to set
-- @return nil
function Store:Set(path, value)
	if SF.Debug then
		SF.Debug:Verbose("SETTINGS", "Setting '%s' to value", path)
	end
	local parent, key = ResolvePath(self.db, path, true)
	local old = parent[key]
	parent[key] = value
	self:_Fire(path, value, old)
end

-- Retrieve a character-specific setting value by dot-path notation
-- @param path string Dot-path like "pressAndHoldCastingBySpec.71"
-- @return any Setting value, or nil if path does not exist
function Store:GetCharacter(path)
	local parent, key = ResolvePath(self.charDb, path, false)
	if not parent then return nil end
	return parent[key]
end

-- Set a character-specific setting value by dot-path notation and trigger callbacks
-- @param path string Dot-path like "pressAndHoldCastingBySpec.71"
-- @param value any The value to set
-- @return nil
function Store:SetCharacter(path, value)
	if SF.Debug then
		SF.Debug:Verbose("SETTINGS", "Setting character '%s' to %s", path, tostring(value))
	end
	local parent, key = ResolvePath(self.charDb, path, true)
	local old = parent[key]
	parent[key] = value
	-- Character-scoped callbacks use a "character." prefix so they stay distinct
	-- from account-scoped paths passed to Store:RegisterCallback.
	self:_Fire("character." .. tostring(path), value, old)
end

-- Get the saved Press and Hold Casting setting for a specialization
-- @param specID number|string Specialization ID
-- @return boolean|nil Saved setting value, or nil if not set
function Store:GetPressAndHoldCastingBySpec(specID)
	if specID == nil then return nil end
	return self:GetCharacter("pressAndHoldCastingBySpec." .. tostring(specID))
end

-- Set the saved Press and Hold Casting setting for a specialization
-- @param specID number|string Specialization ID
-- @param enabled boolean Whether Press and Hold Casting should be enabled
-- @return nil
function Store:SetPressAndHoldCastingBySpec(specID, enabled)
	if specID == nil then return end
	self:SetCharacter("pressAndHoldCastingBySpec." .. tostring(specID), enabled and true or false)
end

-- Ensure all player specializations have a saved Press and Hold Casting value
-- @param defaultEnabled boolean Default setting used for any missing specs
-- @return nil
function Store:EnsurePressAndHoldCastingDefaultsForPlayer(defaultEnabled)
	if not UnitClass or not GetNumSpecializationsForClassID or not GetSpecializationInfoForClassID then
		return
	end

	local _, _, classID = UnitClass("player")
	if not classID then return end

	local specCount = GetNumSpecializationsForClassID(classID)
	if not specCount or specCount < 1 then return end

	for specIndex = 1, specCount do
		local specID = GetSpecializationInfoForClassID(classID, specIndex)
		if specID and self:GetPressAndHoldCastingBySpec(specID) == nil then
			self:SetPressAndHoldCastingBySpec(specID, defaultEnabled and true or false)
		end
	end
end

-- Register a callback to be called when a setting at path changes
-- @param path string Dot-path to watch for changes
-- @param fn function Callback function(newValue, oldValue, path, ...)
-- @return nil
function Store:RegisterCallback(path, fn)
	self._callbacks = self._callbacks or {}
	self._callbacks[path] = self._callbacks[path] or {}
	table.insert(self._callbacks[path], fn)
end

-- Internal: trigger all callbacks registered for a setting path
-- @param path string Path of the setting that changed
-- @param newValue any New value of the setting
-- @param oldValue any Previous value of the setting
-- @param ... any Additional context arguments passed to callbacks
-- @return nil
function Store:_Fire(path, newValue, oldValue, ...)
	if not self._callbacks then return end
	local list = self._callbacks[path]
	if not list then return end

	for _, fn in ipairs(list) do
		pcall(fn, newValue, oldValue, path, ...)
	end
end

-- ----------------------------
-- Profiles
-- ----------------------------

-- Get the loot helper profiles table
-- @return table Dictionary of loot helper profiles
function Store:GetProfiles()
	return self.db.lootHelper.profiles
end

-- Get the name of the currently active loot helper profile
-- @return string|nil Name of active profile or nil if none active
function Store:GetActiveProfileName()
	return self.db.lootHelper.activeProfile
end

-- Get the active profile object
-- @return table|nil The active profile object or nil if none active
function Store:GetActiveProfile()
	local name = self:GetActiveProfileName()
	return self.db.lootHelper.profiles[name]
end

-- Set the active loot helper profile by name
-- @param name string Name of profile to activate
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:SetActiveProfile(name)
	local profiles = self:GetProfiles()
	if not profiles[name] then
		if SF.Debug then
			SF.Debug:Warn("SETTINGS", "Attempted to set non-existent profile '%s' as active", name)
		end
		return false, "Profile does not exist."
	end

	local old = self.db.lootHelper.activeProfile
	self.db.lootHelper.activeProfile = name

	if SF.Debug then
		SF.Debug:Info("SETTINGS", "Active profile changed from '%s' to '%s'", tostring(old), tostring(name))
	end

	-- Fire a callback so UI can refresh dependent controls if it wants
	self:_Fire("lootHelper.activeProfile", name, old)
	return true
end

-- Create a new loot helper profile with given name
-- @param name string Name for the new profile
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:CreateProfile(name)
	local ok, err = IsValidProfileName(name)
	if not ok then
		if SF.Debug then
			SF.Debug:Warn("SETTINGS", "Invalid profile name '%s': %s", name, err)
		end
		return false, err
	end
	name = Trim(name)

	local profiles = self:GetProfiles()
	if profiles[name] then
		if SF.Debug then
			SF.Debug:Warn("SETTINGS", "Attempted to create profile '%s' but it already exists", name)
		end
		return false, "A profile with that name already exists."
	end

	-- Copy template shape from Default (safe + consistent)
	local template = SF.SettingsSchema.DEFAULTS.lootHelper.profiles.Default
	profiles[name] = DeepCopy(template)

	if SF.Debug then
		SF.Debug:Info("SETTINGS", "Created new profile '%s'", name)
	end

	-- Auto-select new profile
	self:SetActiveProfile(name)
	return true
end

-- Delete a loot helper profile by name
-- @param name string Name of profile to delete
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:DeleteProfile(name)
	name = Trim(name)
	local profiles = self:GetProfiles()

	if not profiles[name] then
		return false, "Profile does not exist."
	end

	-- Don’t allow deleting the last remaining profile
	local count = 0
	for _ in pairs(profiles) do count = count + 1 end
	if count <= 1 then
		return false, "You cannot delete the last remaining profile."
	end

	profiles[name] = nil

	-- If we deleted active profile, pick another
	if self.db.lootHelper.activeProfile == name then
		for otherName in pairs(profiles) do
			self:SetActiveProfile(otherName)
			break
		end
	end

	return true
end

-- Internal: ensure default profile exists and active profile is valid
-- @return nil
function Store:_EnsureActiveProfile()
	local profiles = self.db.lootHelper.profiles
	if type(profiles) ~= "table" then
		self.db.lootHelper.profiles = {}
		profiles = self.db.lootHelper.profiles
	end

	if not profiles.Default then
		profiles.Default = DeepCopy(SF.SettingsSchema.DEFAULTS.lootHelper.profiles.Default)
	end

	local active = self.db.lootHelper.activeProfile
	if not active or not profiles[active] then
		self.db.lootHelper.activeProfile = "Default"
	end
end

-- Get a specific setting from the active profile with fallback default
-- @param key string Setting key to retrieve
-- @param defaultValue any Value to return if setting not found
-- @return any Setting value or defaultValue
function Store:GetActiveProfileSetting(key, defaultValue)
	local prof = self:GetActiveProfile()
	if not prof then return defaultValue end

	local v = prof[key]
	if v ==  nil then return defaultValue end
	return v
end

-- Set a specific setting in the active profile and trigger callbacks
-- @param key string Setting key to set
-- @param value any New value for the setting
-- @return boolean True if successful, false if no active profile
function Store:SetActiveProfileSetting(key, value)
	local prof = self:GetActiveProfile()
	if not prof then return false end

	local old = prof[key]
	prof[key] = value

	self:_Fire("lootHelper.profile." .. tostring(key), value, old, {
		profileName = self:GetActiveProfileName(),
		key = key,
	})

	return true
end

-- Get default value for a setting path from schema
-- @param path string Dot-path to setting default
-- @return any Default value or nil if not defined
function Store:GetDefaults(path)
	local defaults = SF.SettingsSchema and SF.SettingsSchema.DEFAULTS
	if not defaults then return nil end

	local parent, key = ResolvePath(defaults, path, false)
	if not parent then return nil end

	return DeepCopy(parent[key])
end

-- Reset a setting to its schema default value
-- @param path string Dot-path to setting
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:ResetPath(path)
	local def = self:GetDefault(path)
	if def == nil then
		return false, "No default exists for: " .. tostring(path)
	end

	self:Set(path, def)
	return true
end

-- Reset multiple settings to their schema default values
-- @param paths table Array of dot-path strings to reset
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:ResetPaths(paths)
	if type(paths) ~= "table" then return false, "paths must be a table" end

	for _, path in ipairs(paths) do
		self:ResetPath(path)
	end
	return true
end

-- Get default value for a profile setting from schema
-- @param key string Setting key to get default for
-- @return any Default value from profile template or nil
function Store:GetProfileDefault(key)
	local defaults = SF.SettingsSchema and SF.SettingsSchema.DEFAULTS
	local template = defaults and defaults.lootHelper and defaults.lootHelper.profiles and defaults.lootHelper.profiles.Default
	if not template then return nil end
	return DeepCopy(template[key])
end

-- Reset multiple profile settings in active profile to defaults
-- @param keys table Array of setting keys to reset
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:ResetActiveProfileKeys(keys)
	if type(keys) ~= "table" then return false, "keys must be a table" end

	for _, key in ipairs(keys) do
		local def = self:GetProfileDefault(key)
		if def ~= nil then
			self:SetActiveProfileSetting(key, def)
		end
	end
	return true
end

-- Reset entire database to schema defaults
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:ResetAll()
	if SF.Debug then
		SF.Debug:Warn("SETTINGS", "Resetting all settings to defaults")
	end

	local defaults = SF.SettingsSchema and SF.SettingsSchema.DEFAULTS
	local characterDefaults = SF.SettingsSchema and SF.SettingsSchema.CHARACTER_DEFAULTS
	if not defaults then return false, "No defaults available" end

	-- Clear current DB but keep the same table reference
	for k in pairs(self.db) do
		self.db[k] = nil
	end
	for k in pairs(self.charDb or {}) do
		self.charDb[k] = nil
	end

	-- Re-apply defaults
	MergeDefaults(self.db, DeepCopy(defaults))
	MergeDefaults(self.charDb, DeepCopy(characterDefaults or {}))
	self:_EnsureActiveProfile()

	if SF.Debug then
		SF.Debug:Info("SETTINGS", "All settings reset to defaults")
	end

	-- Fire a single reset signal; Apply module can re-apply everything
	self:_Fire("sf.reset", true, false)

	return true
end 

-- Internal: ensure loot helper structure exists in database
-- @return nil
function Store:_EnsureLootHelper()
	self.db.lootHelper = self.db.lootHelper or {}
	local lh = self.db.lootHelper

	if type(lh.profiles) ~= "table" then lh.profiles = {} end
	if lh.activeProfileId ~= nil and type(lh.activeProfileId) ~= "string" then
		lh.activeProfileId = nil
	end

	-- If active points to missing profile, clear it
	if lh.activeProfileId and not lh.profiles[lh.activeProfileId] then
		lh.activeProfileId = nil
	end
end

-- Get all loot helper profiles
-- @return table Dictionary of loot helper profiles
function Store:GetLootHelperProfiles()
	return self.db.lootHelper.profiles
end

-- Check if any loot helper profiles exist
-- @return boolean True if profiles exist, false otherwise
function Store:HasLootHelperProfiles()
	return next(self.db.lootHelper.profiles) ~= nil
end

-- Get the stable ID of the active loot helper profile
-- @return string|nil Active profile ID or nil if none active
function Store:GetActiveLootHelperProfileId()
	return self.db.lootHelper.activeProfileId
end

-- Get the active loot helper profile LootProfile object
-- @return LootProfile|nil Active profile object or nil if none active
function Store:GetActiveLootHelperProfileObject()
	return SF.GetActiveProfile and SF:GetActiveProfile() or nil
end

-- Set active loot helper profile by stable profile ID
-- @param profileId string|nil Profile ID to activate, or nil to deactivate
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:SetActiveLootHelperProfileId(profileId)
	if profileId == nil then
		if SF.lootHelperDB then
			SF.lootHelperDB.activeProfileId = nil
			SF.lootHelperDB.activeProfile = nil
		end
		return true
	end

	if SF.SetActiveProfileById then
		local ok = SF:SetActiveProfileById(profileId)
		if not ok then
			return false, "Failed to set active loot helper profile to ID: " .. tostring(profileId)
		end
		return true
	end

	return false, "SetActiveProfileById not available"
end

-- Get raw profile data table for active loot helper profile
-- @return table|nil Active profile data table or nil if none active
function Store:GetActiveLootHelperProfileData()
	local id = self:GetActiveLootHelperProfileId()
	if not id then return nil end
	return self.db.lootHelper.profiles[id]
end

-- Check if an active loot helper profile is set
-- @return boolean True if active profile exists, false otherwise
function Store:HasActiveLootHelperProfile()
	return self:GetActiveLootHelperProfileData() ~= nil
end

-- Get sorted array of loot helper profiles for dropdown/UI display
-- @return table Array of {value=id, label=name} sorted by label
function Store:GetLootHelperProfileOptionsSorted()
	local out = {}
	for id, p in pairs(self.db.lootHelper.profiles) do
		local name = (type(p) == "table" and p.name) or id
		table.insert(out, { value = id, label = tostring(name) })
	end

	table.sort(out, function(a, b) return a.label < b.label end)
	return out
end

-- Get loot helper profile options from SF namespace
-- @return table Array of profile option tables
function Store:GetLootHelperProfileOptions()
	return (SF.GetLootHelperProfileOptions and SF:GetLootHelperProfileOptions()) or {}
end

-- Find a loot helper profile ID by profile name
-- @param name string Profile name to search for
-- @return string|nil Profile ID if found, nil otherwise
function Store:FindLootHelperProfileIdByName(name)
	name = (name or ""):match("^%s*(.-)%s*$")
	for id, p in pairs(self.db.lootHelper.profiles) do
		if type(p) == "table" and p.name == name then
			return id
		end
	end
	return nil
end

-- Create a new loot helper profile by delegating to SF namespace
-- @param profileName string Name for new profile
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:CreateLootHelperProfile(profileName)
	if SF.CreateLootHelperProfile then
		return SF:CreateLootHelperProfile(profileName)
	end
	return false, "CreateLootHelperProfile not implemented"
end

-- Delete a loot helper profile by delegating to SF namespace
-- @param profileId string Profile ID to delete
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:DeleteLootHelperProfile(profileId)
	if SF.DeleteLootHelperProfile then
		return SF:DeleteLootHelperProfile(profileId)
	end
	return false, "DeleteLootHelperProfile not implemented"
end

-- Reset all loot helper settings by delegating to SF namespace
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:ResetAllLootHelperSettings()
	if SF.ResetAllLootHelperSettings then
		return SF:ResetAllLootHelperSettings()
	end
	return false, "ResetAllLootHelperSettings not implemented"
end

-- Reset current loot helper profile settings
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:ResetCurrentLootHelperProfile()
	return false, "Not implemented"
end

-- Add a member as admin to active profile by delegating to SF namespace
-- @param memberId string Member ID to promote to admin
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:AddAdminToActiveProfile(memberId)
	if SF.Debug then
		SF.Debug:Info("STORE", "AddAdminToActiveProfile called with memberId: %s", tostring(memberId))
	end
	
	if SF.AddAdminToActiveLootHelperProfile then
		local ok, err = SF:AddAdminToActiveLootHelperProfile(memberId)
		if SF.Debug then
			SF.Debug:Info("STORE", "AddAdminToActiveLootHelperProfile returned: ok=%s, err=%s", tostring(ok), tostring(err))
		end
		return ok, err
	end
	
	if SF.Debug then
		SF.Debug:Warn("STORE", "AddAdminToActiveLootHelperProfile not implemented")
	end
	return false, "AddAdminToActiveLootHelperProfile not implemented"
end

-- Remove admin status from member in active profile by delegating to SF namespace
-- @param memberId string Member ID to remove from admins
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:RemoveAdminFromActiveProfile(memberId)
	if SF.RemoveAdminFromActiveLootHelperProfile then
		return SF:RemoveAdminFromActiveLootHelperProfile(memberId)
	end
	return false, "RemoveAdminFromActiveLootHelperProfile not implemented"
end

-- Transfer all member history from one active profile member to another
-- @param sourceMemberId string Member ID to transfer history from
-- @param targetMemberId string Member ID to transfer history to
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:TransferMemberHistoryInActiveProfile(sourceMemberId, targetMemberId)
	if SF.TransferMemberHistoryInActiveLootHelperProfile then
		return SF:TransferMemberHistoryInActiveLootHelperProfile(sourceMemberId, targetMemberId)
	end
	return false, "TransferMemberHistoryInActiveLootHelperProfile not implemented"
end

-- Rename the active loot helper profile by delegating to SF namespace
-- @param newName string New name for the profile
-- @return boolean True on success, false on failure
-- @return string|nil Error message if failed
function Store:RenameActiveLootHelperProfile(newName)
	if SF.RenameActiveLootHelperProfile then
		return SF:RenameActiveLootHelperProfile(newName)
	end
	return false, "RenameActiveLootHelperProfile not implemented"
end
