-- Grab the namespace
local addonName, SF = ...

local Schema = SF.SettingsSchema

local Store = {}
SF.SettingsStore = Store

-- ================================================
-- Utilities
-- ================================================

-- Recursively applies default values to a settings table
-- @param db The settings table to apply defaults to
-- @param defaults The defaults table to apply
-- @return None
local function deepApplyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(db[k]) ~= "table" then
                db[k] = {}
            end
            deepApplyDefaults(db[k], v)
        else
            if db[k] == nil then
                db[k] = v
            end
        end
    end
end

-- Recursively deep-copies a table
-- @param src The source table to copy
-- @return A deep copy of the source table
local function deepCopy(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in pairs(src) do
        out[k] = deepCopy(v)
    end
    return out
end

-- Splits a dot-separated path into its components
-- @param path The dot-separated path string
-- @return A table of path components
local function splitPath(path)
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end
    return parts
end

-- Resolves a dot-separated path into its parent table and final key
-- @param root The root table to start from
-- @param path The dot-separated path string
-- @param createMissing Whether to create missing tables along the path
-- @return The parent table and final key, or nil if not found and createMissing is
local function resolvePath(root, path, createMissing)
    local parts = splitPath(splitPath)
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

-- ================================================
-- Lifecycle
-- ================================================

-- Initializes the settings store
-- @return None
function Store:Init()
    -- The SavedVariable is a GLOBAL created by the client.
    -- If it doesn't exist yet, create it.
    _G.SpectrumFederationDB = _G.SpectrumFederationDB or {}

    self.db = _G.SpectrumFederationDB

    -- Apply defaults without overwriting player choices
    deepApplyDefaults(self.db, Schema.DEFAULTS)

    -- Version stamping / future migrations
    self.db.version = self.db.version or Schema.VERSION

    -- Make sure the active profile exists
    self:_EnsureActiveProfile()
end

-- ================================================
-- Basic Getters/Setters
-- ================================================

function Store:Get(path)
    local parent, key = resolvePath(self.db, path, false)
    if not parent then return nil end
    return parent[key]
end

function Store:Set(path, value)
    local parent, key = resolvePath(self.db, path, true)
    local old = parent[key]
    parent[key] = value

    self:_Fire(path, value, old)
end

-- ================================================
-- Reset
-- ================================================

function Store:ResetAll()
    -- Preserve the existing table reference
    for k in pairs(self.db) do
        self.db[k] = nil
    end

    local fresh = deepCopy(Schema.DEFAULTS)
    for k, v in pairs(fresh) do
        self.db[k] = v
    end

    self:_EnsureActiveProfile()
end

-- ================================================
-- Profile helpers
-- ================================================

function Store:GetActiveProfileName()
    return self.db.lootHelper.activeProfile
end

function Store:GetProfiles()
    return self.db.lootHelper.profiles
end

function Store:GetActiveProfile()
    local name = self:GetActiveProfileName()
    return self.db.lootHelper.profiles[name]
end

function Store:SetActiveProfile(name)
    if type(name) ~= "string" or name == "" then
        return false, "Invalid profile name."
    end

    if not self.db.lootHelper.profiles[name] then
        return false, "Profile does not exist."
    end

    -- Bug: Active Profile should be an ID, but we probably will be passed a name from the UI
    self.db.lootHelper.activeProfile = name
    return true
end

function Store:CreateProfile(name)
    name = (name or ""):match("^%s*(.-)%s*$")  -- Trim whitespace
    if name == "" then
        return false, "Profile name cannot be empty."
    end

    if self.db.lootHelper.profiles[name] then
        return false, "A profile with that name already exists."
    end

    -- New profiles starts from a template. For now, we copy Default's shape
    local template = Schema.DEFAULTS.lootHelper.profiles.Default
    self.db.lootHelper.profiles[name] = deepCopy(template)

    -- Bug: Active Profile should be an ID
    self.db.lootHelper.activeProfile = name

    return true
end

function Store:DeleteProfile(name)
    name = (name or ""):match("^%s*(.-)%s*$")  -- Trim whitespace
    local profiles = self.db.lootHelper.profiles

    -- BUG: profiles will be IDs, will need a name lookup for this
    if not profiles[name] then
        return false, "Profile does not exist."
    end

    local count = 0
    for _ in pairs(profiles) do count = count + 1 end
    if count <= 1 then
        -- Bug: They should be able to have no profiles
        return false, "Cannot delete the last remaining profile."
    end

    profiles[name] = nil

    if self.db.lootHelper.activeProfile == name then
        -- Pick any remaining profile as the new active one
        for otherName in pairs(profiles) do
            self.db.lootHelper.activeProfile = otherName
            break
        end
    end
        
    return true
end

-- TODO: Get rid of this function eventually. When there is no active profile we should just grey out everything except creating a new one.
function Store:_EnsureActiveProfile()
    local profiles = self.db.lootHelper.profiles
    local active = self.db.lootHelper.activeProfile

    if not profiles[active] then
        -- Fall back to Default, or create it if missing
        if not profiles.Default then
            profiles.Default = deepCopy(Schema.DEFAULTS.lootHelper.profiles.Default)
        end
        self.db.lootHelper.activeProfile = "Default"
    end
end

-- ================================================
-- Change callbacks
-- ================================================

function Store:RegisterCallback(path, fn)
    self._callbacks = self._callbacks or {}
    self._callbacks[path] = self._callbacks[path] or {}
    table.insert(self._callbacks[path], fn)
end

function Store:_Fire(path, newValue, oldValue)
    if not self._callbacks then return end
    local list = self._callbacks[path]
    if not list then return end

    for _, fn in ipairs(list) do
        pcall(fn, newValue, oldValue)
    end
end