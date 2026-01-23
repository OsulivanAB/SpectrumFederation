-- Grab the namespace
local addonName, SF = ...

SF.SettingsStore = SF.SettingsStore or {}
local Store = SF.SettingsStore

local function DeepCopy(src)
	if type(src) ~= "table" then return src end
	local dst = {}
	for k, v in pairs(src) do
		dst[k] = DeepCopy(v)
	end
	return dst
end

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

local function SplitPath(path)
	local parts = {}
	for part in string.gmatch(path, "[^%.]+") do
		table.insert(parts, part)
	end
	return parts
end

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

local function Trim(s)
	return (s or ""):match("^%s*(.-)%s*$")
end

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

	SpectrumFederationDB = SpectrumFederationDB or {}
	self.db = SpectrumFederationDB

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

function Store:Get(path)
	local parent, key = ResolvePath(self.db, path, false)
	if not parent then return nil end
	return parent[key]
end

function Store:Set(path, value)
	if SF.Debug then
		SF.Debug:Verbose("SETTINGS", "Setting '%s' to value", path)
	end
	local parent, key = ResolvePath(self.db, path, true)
	local old = parent[key]
	parent[key] = value
	self:_Fire(path, value, old)
end

function Store:RegisterCallback(path, fn)
	self._callbacks = self._callbacks or {}
	self._callbacks[path] = self._callbacks[path] or {}
	table.insert(self._callbacks[path], fn)
end

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

function Store:GetProfiles()
	return self.db.lootHelper.profiles
end

function Store:GetActiveProfileName()
	return self.db.lootHelper.activeProfile
end

function Store:GetActiveProfile()
	local name = self:GetActiveProfileName()
	return self.db.lootHelper.profiles[name]
end

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

function Store:GetActiveProfileSetting(key, defaultValue)
	local prof = self:GetActiveProfile()
	if not prof then return defaultValue end

	local v = prof[key]
	if v ==  nil then return defaultValue end
	return v
end

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

function Store:GetDefaults(path)
	local defaults = SF.SettingsSchema and SF.SettingsSchema.DEFAULTS
	if not defaults then return nil end

	local parent, key = ResolvePath(defaults, path, false)
	if not parent then return nil end

	return DeepCopy(parent[key])
end

function Store:ResetPath(path)
	local def = self:GetDefault(path)
	if def == nil then
		return false, "No default exists for: " .. tostring(path)
	end

	self:Set(path, def)
	return true
end

function Store:ResetPaths(paths)
	if type(paths) ~= "table" then return false, "paths must be a table" end

	for _, path in ipairs(paths) do
		self:ResetPath(path)
	end
	return true
end

function Store:GetProfileDefault(key)
	local defaults = SF.SettingsSchema and SF.SettingsSchema.DEFAULTS
	local template = defaults and defaults.lootHelper and defaults.lootHelper.profiles and defaults.lootHelper.profiles.Default
	if not template then return nil end
	return DeepCopy(template[key])
end

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

function Store:ResetAll()
	if SF.Debug then
		SF.Debug:Warn("SETTINGS", "Resetting all settings to defaults")
	end

	local defaults = SF.SettingsSchema and SF.SettingsSchema.DEFAULTS
	if not defaults then return false, "No defaults available" end

	-- Clear current DB but keep the same table reference
	for k in pairs(self.db) do
		self.db[k] = nil
	end

	-- Re-apply defaults
	MergeDefaults(self.db, DeepCopy(defaults))
	self:_EnsureActiveProfile()

	if SF.Debug then
		SF.Debug:Info("SETTINGS", "All settings reset to defaults")
	end

	-- Fire a single reset signal; Apply module can re-apply everything
	self:_Fire("sf.reset", true, false)

	return true
end 

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

function Store:GetLootHelperProfiles()
	return self.db.lootHelper.profiles
end

function Store:HasLootHelperProfiles()
	return next(self.db.lootHelper.profiles) ~= nil
end

function Store:GetActiveLootHelperProfileId()
	return self.db.lootHelper.activeProfileId
end

function Store:GetActiveLootHelperProfileObject()
	-- TODO: Implement Later
	return false, "Not implemented"
end

function Store:SetActiveLootHelperProfileId(profileId)
	if profileId == nil then
		if SF.Debug then
			SF.Debug:Info("SETTINGS", "Clearing active LootHelper profile")
		end
		local old = self.db.lootHelper.activeProfileId
		self.db.lootHelper.activeProfileId = nil
		self:_Fire("lootHelper.activeProfileId", nil, old)
		return true
	end

	if type(profileId) ~= "string" then
		if SF.Debug then
			SF.Debug:Warn("SETTINGS", "Invalid profile id type: %s", type(profileId))
		end
		return false, "Invalid profile id."
	end

	local profiles = self:GetLootHelperProfiles()
	if not profiles[profileId] then
		if SF.Debug then
			SF.Debug:Warn("SETTINGS", "Attempted to set non-existent LootHelper profile '%s' as active", profileId)
		end
		return false, "Profile does not exist."
	end

	local old = self.db.lootHelper.activeProfileId
	self.db.lootHelper.activeProfileId = profileId

	if SF.Debug then
		SF.Debug:Info("SETTINGS", "Active LootHelper profile changed from '%s' to '%s'", tostring(old), tostring(profileId))
	end

	self:_Fire("lootHelper.activeProfileId", profileId, old)

	return true
end

function Store:GetActiveLootHelperProfileData()
	local id = self:GetActiveLootHelperProfileId()
	if not id then return nil end
	return self.db.lootHelper.profiles[id]
end

function Store:HasActiveLootHelperProfile()
	return self:GetActiveLootHelperProfileData() ~= nil
end

function Store:GetLootHelperProfileOptionsSorted()
	local out = {}
	for id, p in pairs(self.db.lootHelper.profiles) do
		local name = (type(p) == "table" and p.name) or id
		table.insert(out, { value = id, label = tostring(name) })
	end

	table.sort(out, function(a, b) return a.label < b.label end)
	return out
end

function Store:FindLootHelperProfileIdByName(name)
	name = (name or ""):match("^%s*(.-)%s*$")
	for id, p in pairs(self.db.lootHelper.profiles) do
		if type(p) == "table" and p.name == name then
			return id
		end
	end
	return nil
end

function Store:CreateLootHelperProfile(profileName)
	return false, "Not implemented"
end

function Store:DeleteLootHelperProfile(profileId)
	return false, "Not implemented"
end

function Store:ResetAllLootHelperSettings()
	return false, "Not implemented"
end

function Store:ResetCurrentLootHelperProfile()
	return false, "Not implemented"
end

function Store:AddAdminToActiveProfile(memberId)
	return false, "Not implemented"
end

function Store:RemoveAdminFromActiveProfile(memberId)
	return false, "Not implemented"
end

function Store:RenameActiveLootHelperProfile(newName)
	return false, "Not implemented"
end