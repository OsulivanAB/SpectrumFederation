-- Grab the namespace
local addonName, SF = ...

SF.SettingsSchema = {
	VERSION = 3,

	DEFAULTS = {
		version = 3,

		global = {
			windowStyle = "Default",
			fontStyle   = "Friz Quadrata",
			fontSize    = 12,
		},

		lootHelper = {
			-- User-level
			enabled = true,
			localSafeMode = false,
			localSafeModeOnCombat = false,
			raidCheckAuditAutoRefresh = false,

			-- Profile system
			activeProfileId = nil,
			profiles = {},
		},
	},

	CHARACTER_DEFAULTS = {},

	-- Default *settings* for a profile
	-- These are the fields we can safely "reset" without nuking membership/admins
	-- Bug: Probably don't need these, Resetting profile settings should be done in the profile class and all these are stored there too.
	PROFILE_SETTINGS_DEFAULTS = {
		pointName = "Points",
		raidWideSafeMode = false,
		raidWideSafeModeOnCombat = false,
	},

	-- Convenience lists (UI can use these)
	ENUMS = {
		windowStyle = { "Default", "Compact", "Minimal" },
		fontStyle   = { "Friz Quadrata", "Arial Narrow", "Morpheus" },
	},

	-- Migration functions run when db.version < VERSION
	-- The key is the *target* version number (migrate to that version)
	MIGRATIONS = {
		[3] = function(db)
			if type(db) ~= "table" then return end
			if type(db.lootHelper) ~= "table" then return end

			local lh = db.lootHelper

			local oldProfiles = lh.profiles
			local oldActiveName = lh.activeProfile

			if type(oldProfiles) ~= "table" then
				-- Ensure new shape
				lh.profiles = {}
				lh.activeProfileId = nil
				lh.activeProfile = nil
				return
			end

			-- If profiles are already id-keyed and values contain .name and .id, skip
			local looksIdKeyed = false
			for k, v in pairs(oldProfiles) do
				if type(k) == "string" and type(v) == "table" and v.id == k and type(v.name) == "string" then
					looksIdKeyed = true
				end
				break
			end
			if looksIdKeyed then
				lh.activeProfileId = lh.activeProfileId or nil
				lh.activeProfile = nil
				return
			end

			-- Helper: generate a simple string id without dots (safe)
			-- TODO: Maybe call our real ID generation function here instead?
			local function genId(existing)
				local base = tostring(time()) .. tostring(math.random(10000, 999999))
				local id = base
				local n = 0
				while existing[id] do
					n = n + 1
					id = base .. "-" .. tostring(n)
				end
				return id
			end

			local newProfiles = {}
			local nameToId = {}
			
			for name, pdata in pairs(oldProfiles) do
				if type(name) == "string" and type(pdata) == "table" then
					local id = genId(newProfiles)

					newProfiles[id] = {
						id = id,
						name = name,

						-- Best-effort carryover:
						-- old safeMode becomes raidWideSafeMode
						raidWideSafeMode = pdata.safeMode and true or false,
						raidWideSafeModeOnCombat = pdata.raidWideSafeModeOnCombat and true or false,

						pointName = pdata.pointName or "Points",

						-- If old data had these, keep them
						ownerId = pdata.ownerId,
						admins = pdata.admins,
						members = pdata.members,
					}

					nameToId[name] = id
				end
			end

			lh.profiles = newProfiles
			lh.activeProfileId = (type(oldActiveName) == "string" and nameToId[oldActiveName]) or nil
			lh.activeProfile = nil			
		end,
		-- v1 -> v2: move old admin.safeMode to all profiles safeMode(if it exists)
		[2] = function(db)
			if not db or type(db) ~= "table" then return end
			if not db.lootHelper or type(db.lootHelper) ~= "table" then return end

			local lh = db.lootHelper
			local admin = lh.admin
			if not admin or type(admin) ~= "table" then return end
			if admin.safeMode == nil then return end

			local oldValue = admin.safeMode and true or false

			-- Ensure profiles exist
			lh.profiles = lh.profiles or {}
			if type(lh.profiles) ~= "table" then
				lh.profiles = {}
			end

			-- Copy legacy value into each profile that doesn't already have safeMode
			for _, profile in pairs (lh.profiles) do
				if type(profile) == "table" and profile.safeMode == nil then
					profile.safeMode = oldValue
				end
			end

			-- Remove old location
			admin.safeMode = nil
			if next(admin) == nil then
				lh.admin = nil
			end
		end,
	},
}
