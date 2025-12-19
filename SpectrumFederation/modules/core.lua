local addonName, ns = ...

-- Local reference to Core module
local Core = ns.Core or {}
ns.Core = Core

-- Roster tracking table - keyed by charKey
Core.roster = {}

-- Simple callback system for roster updates
Core.callbacks = {}

-- InitDatabase: Initializes the SavedVariables database structure
-- Ensures all required tables and fields exist with proper defaults
function Core:InitDatabase()
    -- Ensure top-level structure exists (should already be created by InitializeNamespace)
    if not ns.db then
        ns.db = SpectrumFederationDB or {}
    end
    
    -- Ensure schema version
    if not ns.db.schemaVersion then
        ns.db.schemaVersion = 1
    end
    
    -- Ensure current tier
    if not ns.db.currentTier then
        ns.db.currentTier = "0.0.0"
    end
    
    -- Ensure tiers table exists
    if not ns.db.tiers then
        ns.db.tiers = {}
    end
    
    -- Ensure UI state structure exists
    if not ns.db.ui then
        ns.db.ui = {
            lootFrame = {
                position = nil,  -- Will store {point, relativeTo, relativePoint, xOfs, yOfs}
                isShown = false
            },
            settingsFrame = {
                position = nil,  -- Will store {x, y}
                isShown = false,
                activeTab = 1
            }
        }
    else
        -- Ensure settingsFrame structure exists even if ui table exists
        if not ns.db.ui.settingsFrame then
            ns.db.ui.settingsFrame = {
                position = nil,
                isShown = false,
                activeTab = 1
            }
        end
        -- Ensure lootFrame structure exists
        if not ns.db.ui.lootFrame then
            ns.db.ui.lootFrame = {
                position = nil,
                isShown = false
            }
        end
    end
    
    -- Ensure settings structure exists
    if not ns.db.settings then
        ns.db.settings = {
            lootWindowEnabled = true,
            lastSyncCoordinator = nil,
            backdropStyle = "Default"
        }
    else
        -- Ensure backdropStyle exists
        if not ns.db.settings.backdropStyle then
            ns.db.settings.backdropStyle = "Default"
        end
    end
    
    -- Ensure current tier data structure exists
    local currentTier = ns.db.currentTier
    if not ns.db.tiers[currentTier] then
        ns.db.tiers[currentTier] = {
            points = {},
            logs = {},
            nextLogId = 1
        }
        
        if ns.Debug then
            ns.Debug:Info("DATABASE", "Initialized new tier: %s", currentTier)
        end
    end
    
    if ns.Debug then
        ns.Debug:Info("DATABASE", "Database initialized (schema v%d, tier: %s)", 
            ns.db.schemaVersion, ns.db.currentTier)
    end
    
    -- Run migration if needed
    self:MigrateSchema()
end

-- MigrateSchema: Migrates database from old schema versions to current
-- Handles conversion from tier-based system (v1) to profile-based system (v2)
function Core:MigrateSchema()
    if not ns.db or not ns.db.schemaVersion then
        if ns.Debug then
            ns.Debug:Error("MIGRATION", "Cannot migrate - no schema version found")
        end
        return
    end
    
    local currentVersion = ns.db.schemaVersion
    
    -- Migration from v1 (tier-based) to v2 (profile-based)
    if currentVersion < 2 then
        if ns.Debug then
            ns.Debug:Info("MIGRATION", "Starting migration from schema v%d to v2", currentVersion)
        end
        
        -- Create new profiles structure
        local profiles = {}
        local allLogs = {}
        local allPoints = {}
        local maxLogId = 0
        
        -- Collect all logs and points from all tiers
        if ns.db.tiers then
            for tierKey, tierData in pairs(ns.db.tiers) do
                if ns.Debug then
                    ns.Debug:Verbose("MIGRATION", "Processing tier: %s", tierKey)
                end
                
                -- Collect logs
                if tierData.logs then
                    for logId, logEntry in pairs(tierData.logs) do
                        allLogs[logId] = logEntry
                        if logId > maxLogId then
                            maxLogId = logId
                        end
                    end
                end
                
                -- Collect points (use most recent values if duplicates)
                if tierData.points then
                    for charKey, pointData in pairs(tierData.points) do
                        if not allPoints[charKey] or 
                           (pointData.lastUpdated and allPoints[charKey].lastUpdated and 
                            pointData.lastUpdated > allPoints[charKey].lastUpdated) then
                            allPoints[charKey] = pointData
                        end
                    end
                end
            end
        end
        
        -- Create Default profile with all collected data
        profiles["Default"] = {
            points = allPoints,
            logs = allLogs,
            nextLogId = maxLogId + 1,
            createdAt = time(),
            createdBy = self:GetCharacterKey("player") or "Unknown"
        }
        
        -- Replace old structure with new profile-based structure
        ns.db.profiles = profiles
        ns.db.activeProfile = "Default"
        
        -- Create/update settings structure
        if not ns.db.settings then
            ns.db.settings = {
                lootWindowEnabled = true,
                lastSyncCoordinator = nil,
                backdropStyle = "Default"
            }
        else
            -- Preserve existing settings, add new ones if missing
            if ns.db.settings.lootWindowEnabled == nil then
                ns.db.settings.lootWindowEnabled = true
            end
            if not ns.db.settings.backdropStyle then
                ns.db.settings.backdropStyle = "Default"
            end
        end
        
        -- Delete old tier-based fields
        ns.db.tiers = nil
        ns.db.currentTier = nil
        
        -- Update schema version
        ns.db.schemaVersion = 2
        
        if ns.Debug then
            ns.Debug:Info("MIGRATION", 
                "Migration complete: %d logs, %d characters migrated to Default profile", 
                maxLogId, self:CountTableKeys(allPoints))
        end
    end
end

-- CountTableKeys: Utility function to count keys in a table
-- @param tbl: The table to count
-- @return: Number of keys in the table
function Core:CountTableKeys(tbl)
    if not tbl then return 0 end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- ========================================================================
-- PROFILE MANAGEMENT FUNCTIONS
-- ========================================================================

-- CreateProfile: Creates a new profile with the given name
-- @param profileName: The name of the profile to create
-- @param creatorCharKey: Optional character key of creator (defaults to player)
-- @return: success (boolean), error message (string or nil)
function Core:CreateProfile(profileName, creatorCharKey)
    -- Validate profile name
    if not profileName or profileName == "" then
        if ns.Debug then
            ns.Debug:Error("PROFILE", "Cannot create profile - name is empty")
        end
        return false, "Profile name cannot be empty"
    end
    
    -- Check for invalid characters and length
    if #profileName > 64 then
        if ns.Debug then
            ns.Debug:Error("PROFILE", "Cannot create profile - name too long (%d chars)", #profileName)
        end
        return false, "Profile name must be 64 characters or less"
    end
    
    -- Check if profile already exists
    if ns.db.profiles and ns.db.profiles[profileName] then
        if ns.Debug then
            ns.Debug:Warn("PROFILE", "Profile '%s' already exists", profileName)
        end
        return false, "Profile already exists"
    end
    
    -- Ensure profiles table exists
    if not ns.db.profiles then
        ns.db.profiles = {}
    end
    
    -- Get creator character key
    local creator = creatorCharKey or self:GetCharacterKey("player") or "Unknown"
    
    -- Create new profile structure
    ns.db.profiles[profileName] = {
        points = {},
        logs = {},
        nextLogId = 1,
        createdAt = time(),
        createdBy = creator
    }
    
    if ns.Debug then
        ns.Debug:Info("PROFILE", "Created profile '%s' by %s", profileName, creator)
    end
    
    return true, nil
end

-- DeleteProfile: Deletes a profile by name
-- @param profileName: The name of the profile to delete
-- @return: success (boolean), error message (string or nil)
function Core:DeleteProfile(profileName)
    if not profileName then
        if ns.Debug then
            ns.Debug:Error("PROFILE", "Cannot delete profile - name is nil")
        end
        return false, "Profile name is required"
    end
    
    -- Check if profile exists
    if not ns.db.profiles or not ns.db.profiles[profileName] then
        if ns.Debug then
            ns.Debug:Warn("PROFILE", "Cannot delete profile '%s' - does not exist", profileName)
        end
        return false, "Profile does not exist"
    end
    
    -- Prevent deletion of active profile
    if ns.db.activeProfile == profileName then
        if ns.Debug then
            ns.Debug:Error("PROFILE", "Cannot delete active profile '%s'", profileName)
        end
        return false, "Cannot delete the active profile"
    end
    
    -- Prevent deletion if it's the only profile
    local profileCount = self:CountTableKeys(ns.db.profiles)
    if profileCount <= 1 then
        if ns.Debug then
            ns.Debug:Error("PROFILE", "Cannot delete '%s' - it's the only profile", profileName)
        end
        return false, "Cannot delete the only remaining profile"
    end
    
    -- Delete the profile
    ns.db.profiles[profileName] = nil
    
    if ns.Debug then
        ns.Debug:Info("PROFILE", "Deleted profile '%s'", profileName)
    end
    
    return true, nil
end

-- GetActiveProfile: Returns the currently active profile data
-- @return: Profile data table or nil if not found
function Core:GetActiveProfile()
    if not ns.db or not ns.db.profiles or not ns.db.activeProfile then
        if ns.Debug then
            ns.Debug:Error("PROFILE", "Cannot get active profile - database not initialized")
        end
        return nil
    end
    
    local profile = ns.db.profiles[ns.db.activeProfile]
    
    -- Fallback to Default if active profile is missing
    if not profile then
        if ns.Debug then
            ns.Debug:Warn("PROFILE", "Active profile '%s' not found, falling back to Default", 
                ns.db.activeProfile)
        end
        ns.db.activeProfile = "Default"
        
        -- Create Default if it doesn't exist
        if not ns.db.profiles["Default"] then
            self:CreateProfile("Default", "System")
        end
        
        profile = ns.db.profiles["Default"]
    end
    
    return profile
end

-- SetActiveProfile: Sets the active profile
-- @param profileName: The name of the profile to activate
-- @return: success (boolean), error message (string or nil)
function Core:SetActiveProfile(profileName)
    if not profileName then
        if ns.Debug then
            ns.Debug:Error("PROFILE", "Cannot set active profile - name is nil")
        end
        return false, "Profile name is required"
    end
    
    -- Check if profile exists, create if it doesn't
    if not ns.db.profiles or not ns.db.profiles[profileName] then
        if ns.Debug then
            ns.Debug:Info("PROFILE", "Profile '%s' doesn't exist, creating it", profileName)
        end
        local success, err = self:CreateProfile(profileName)
        if not success then
            return false, err
        end
    end
    
    -- Set as active
    ns.db.activeProfile = profileName
    
    if ns.Debug then
        ns.Debug:Info("PROFILE", "Active profile set to '%s'", profileName)
    end
    
    -- Fire callback for UI updates
    self:FireCallback("PROFILE_CHANGED")
    
    return true, nil
end

-- GetProfileList: Returns a sorted array of all profile names
-- @return: Array of profile name strings
function Core:GetProfileList()
    if not ns.db or not ns.db.profiles then
        return {}
    end
    
    local profiles = {}
    for name in pairs(ns.db.profiles) do
        table.insert(profiles, name)
    end
    
    -- Sort alphabetically
    table.sort(profiles)
    
    return profiles
end

-- GetActiveProfileName: Returns the name of the currently active profile
-- @return: Profile name string
function Core:GetActiveProfileName()
    return ns.db and ns.db.activeProfile or "Default"
end

-- ========================================================================
-- END PROFILE MANAGEMENT FUNCTIONS
-- ========================================================================

-- GetCurrentTierData: Returns the data table for the current profile (legacy compatibility)
-- This function now wraps GetActiveProfile() for backward compatibility
-- @return: Profile data table containing points, logs, and nextLogId
function Core:GetCurrentTierData()
    return self:GetActiveProfile()
end

-- GetCharacterKey: Converts a unit ID or name into a "Name-Realm" key
-- @param unitOrName: Either a unit ID ("player", "raid1") or a character name
-- @return: String in format "Name-Realm" or nil on failure
function Core:GetCharacterKey(unitOrName)
    local name, realm
    
    -- If it's a unit ID, get the name from it
    if UnitExists(unitOrName) then
        name, realm = UnitName(unitOrName)
    else
        -- Assume it's already a name, try to parse it
        if string.find(unitOrName, "-") then
            -- Already has realm
            name, realm = string.match(unitOrName, "^([^-]+)-(.+)$")
        else
            -- No realm specified, use player's realm
            name = unitOrName
            realm = GetRealmName()
        end
    end
    
    -- If no realm, use player's realm as default
    if not realm or realm == "" then
        realm = GetRealmName()
    end
    
    if not name or name == "" then
        if ns.Debug then
            ns.Debug:Warn("DATABASE", "Could not determine character key from: %s", tostring(unitOrName))
        end
        return nil
    end
    
    return string.format("%s-%s", name, realm)
end

-- GetPoints: Retrieves the current point total for a character
-- @param charKey: Character key in "Name-Realm" format
-- @return: Integer point total (0 if character has no points)
function Core:GetPoints(charKey)
    local tierData = self:GetCurrentTierData()
    if not tierData or not tierData.points then
        return 0
    end
    
    if tierData.points[charKey] and tierData.points[charKey].total then
        return tierData.points[charKey].total
    end
    
    return 0
end

-- SetPoints: Updates a character's points and logs the change
-- @param charKey: Character key in "Name-Realm" format (target)
-- @param newTotal: The new point total
-- @param actorCharKey: Character key of who made the change
-- @param reason: String description of why points changed
-- @param deltaOverride: Optional delta value (calculated if nil)
-- @return: Boolean success status
function Core:SetPoints(charKey, newTotal, actorCharKey, reason, deltaOverride)
    local tierData = self:GetCurrentTierData()
    if not tierData then
        if ns.Debug then
            ns.Debug:Error("POINTS_UPDATE", "Cannot set points - tier data not available")
        end
        return false
    end
    
    -- Get old total for delta calculation
    local oldTotal = self:GetPoints(charKey)
    local delta = deltaOverride or (newTotal - oldTotal)
    
    -- Update points
    if not tierData.points[charKey] then
        tierData.points[charKey] = {}
    end
    
    tierData.points[charKey].total = newTotal
    tierData.points[charKey].lastUpdated = time()
    
    -- Build log entry and append via LootLog module
    local logEntry = {
        actor = actorCharKey,
        target = charKey,
        delta = delta,
        newTotal = newTotal,
        reason = reason or "Unknown"
    }
    
    -- Append to log via LootLog module
    local success, logId = false, nil
    if ns.LootLog then
        success, logId = ns.LootLog:AppendEntry(logEntry)
    end
    
    if not success then
        if ns.Debug then
            ns.Debug:Warn("POINTS_UPDATE", "Log entry was not written for %s", charKey)
        end
    else
        -- Get the full log entry that was created for sync
        if ns.Sync and logId then
            local tierData = self:GetCurrentTierData()
            if tierData and tierData.logs and tierData.logs[logId] then
                ns.Sync:OnPointsChanged(tierData.logs[logId])
            end
        end
    end
    
    -- Debug logging
    if ns.Debug then
        ns.Debug:Info("POINTS_UPDATE", 
            "Player %s: %d → %d (delta: %+d) by %s. Reason: %s",
            charKey, oldTotal, newTotal, delta, actorCharKey, reason)
    end
    
    return true
end

-- RefreshRoster: Updates the in-memory roster from current group/raid
-- Clears stale entries and populates with current group members
function Core:RefreshRoster()
    -- Track previous group state for sync triggering
    local wasInGroup = self.wasInGroup or false
    
    -- Clear existing roster
    self.roster = {}
    
    local inRaid = IsInRaid()
    local inGroup = IsInGroup()
    local currentlyInGroup = inRaid or inGroup
    
    if not currentlyInGroup then
        -- Not in any group, only track player
        local playerKey = self:GetCharacterKey("player")
        if playerKey then
            local name, realm = UnitName("player")
            local _, class = UnitClass("player")
            
            self.roster[playerKey] = {
                name = name,
                realm = realm or GetRealmName(),
                charKey = playerKey,
                class = class,
                role = nil,
                isOnline = true,
                isInRaid = false,
                unitId = "player"
            }
        end
        
        if ns.Debug then
            ns.Debug:Verbose("ROSTER", "Not in group - roster contains only player")
        end
        return
    end
    
    local numMembers = GetNumGroupMembers()
    local groupType = inRaid and "raid" or "party"
    
    if ns.Debug then
        ns.Debug:Verbose("ROSTER", "Refreshing roster: %s with %d members", groupType, numMembers)
    end
    
    if inRaid then
        -- Process raid members
        for i = 1, numMembers do
            local unitId = "raid" .. i
            if UnitExists(unitId) then
                local name, realm = UnitName(unitId)
                local charKey = self:GetCharacterKey(unitId)
                
                if charKey then
                    local _, class = UnitClass(unitId)
                    local role = UnitGroupRolesAssigned(unitId)
                    local isOnline = UnitIsConnected(unitId)
                    
                    self.roster[charKey] = {
                        name = name,
                        realm = realm or GetRealmName(),
                        charKey = charKey,
                        class = class,
                        role = role,
                        isOnline = isOnline,
                        isInRaid = true,
                        unitId = unitId
                    }
                end
            end
        end
    else
        -- Process party members (including player)
        -- Add player
        local playerKey = self:GetCharacterKey("player")
        if playerKey then
            local name, realm = UnitName("player")
            local _, class = UnitClass("player")
            local role = UnitGroupRolesAssigned("player")
            
            self.roster[playerKey] = {
                name = name,
                realm = realm or GetRealmName(),
                charKey = playerKey,
                class = class,
                role = role,
                isOnline = true,
                isInRaid = false,
                unitId = "player"
            }
        end
        
        -- Add party members
        for i = 1, numMembers - 1 do
            local unitId = "party" .. i
            if UnitExists(unitId) then
                local name, realm = UnitName(unitId)
                local charKey = self:GetCharacterKey(unitId)
                
                if charKey then
                    local _, class = UnitClass(unitId)
                    local role = UnitGroupRolesAssigned(unitId)
                    local isOnline = UnitIsConnected(unitId)
                    
                    self.roster[charKey] = {
                        name = name,
                        realm = realm or GetRealmName(),
                        charKey = charKey,
                        class = class,
                        role = role,
                        isOnline = isOnline,
                        isInRaid = false,
                        unitId = unitId
                    }
                end
            end
        end
    end
    
    -- Count roster size for logging
    local rosterSize = 0
    for _ in pairs(self.roster) do
        rosterSize = rosterSize + 1
    end
    
    if ns.Debug then
        ns.Debug:Info("ROSTER", "Roster refreshed: %d members in %s", rosterSize, groupType)
    end
    
    -- Fire callbacks
    self:FireCallback("ROSTER_UPDATED")
    
    -- Check if we just joined a group (transition from solo to grouped)
    if currentlyInGroup and not wasInGroup then
        if ns.Debug then
            ns.Debug:Info("ROSTER", "Joined group - triggering sync request")
        end
        
        -- Throttle sync requests (don't spam if roster updates rapidly)
        local now = time()
        local lastSyncRequest = self.lastSyncRequestTime or 0
        
        if now - lastSyncRequest >= 5 then
            self.lastSyncRequestTime = now
            
            -- Request sync from other addon users
            if ns.Sync and ns.Sync.SendSyncRequest then
                ns.Sync:SendSyncRequest()
            end
        else
            if ns.Debug then
                ns.Debug:Verbose("ROSTER", "Sync request throttled (last request %d seconds ago)", 
                    now - lastSyncRequest)
            end
        end
    end
    
    -- Update state for next call
    self.wasInGroup = currentlyInGroup
end

-- RegisterCallback: Register a callback function for an event
-- @param event: Event name (e.g., "ROSTER_UPDATED")
-- @param callback: Function to call when event fires
function Core:RegisterCallback(event, callback)
    if not event or type(event) ~= "string" then
        if ns.Debug then
            ns.Debug:Error("CALLBACK", "Cannot register callback - invalid event name")
        end
        return
    end
    
    if not callback or type(callback) ~= "function" then
        if ns.Debug then
            ns.Debug:Error("CALLBACK", "Cannot register callback for %s - callback is not a function", event)
        end
        return
    end
    
    if not self.callbacks[event] then
        self.callbacks[event] = {}
    end
    table.insert(self.callbacks[event], callback)
    
    if ns.Debug then
        ns.Debug:Verbose("CALLBACK", "Registered callback for event: %s", event)
    end
end

-- FireCallback: Fire all callbacks for an event
-- @param event: Event name
function Core:FireCallback(event)
    if not event then
        if ns.Debug then
            ns.Debug:Error("CALLBACK", "Cannot fire callback - event is nil")
        end
        return
    end
    
    if self.callbacks[event] then
        for i, callback in ipairs(self.callbacks[event]) do
            if type(callback) == "function" then
                local success, err = pcall(callback)
                if not success and ns.Debug then
                    ns.Debug:Error("CALLBACK", "Error in callback #%d for %s: %s", i, event, tostring(err))
                end
            else
                if ns.Debug then
                    ns.Debug:Error("CALLBACK", "Invalid callback #%d for %s (not a function)", i, event)
                end
            end
        end
        
        if ns.Debug then
            ns.Debug:Verbose("CALLBACK", "Fired %d callbacks for event: %s", #self.callbacks[event], event)
        end
    end
end

-- GetRoster: Returns a shallow copy of the current roster
-- @return: Table of roster entries keyed by charKey
function Core:GetRoster()
    local copy = {}
    for charKey, data in pairs(self.roster) do
        copy[charKey] = data
    end
    return copy
end

-- RecalculatePointsFromLogs: Rebuild all points from log history for a profile
-- This is the authoritative way to ensure points are correct after sync operations
-- @param profileName: The profile to recalculate. If nil, uses active profile
function Core:RecalculatePointsFromLogs(profileName)
    -- Resolve profile name
    local profile = profileName
    if not profile then
        if ns.Core then
            profile = self:GetActiveProfileName()
        else
            if ns.Debug then
                ns.Debug:Error("CORE", "Cannot recalculate points - no profile specified and Core not available")
            end
            return
        end
    end
    
    -- Get profile data
    if not ns.db or not ns.db.profiles then
        if ns.Debug then
            ns.Debug:Error("CORE", "Cannot recalculate points - database not initialized")
        end
        return
    end
    
    local profileData = ns.db.profiles[profile]
    if not profileData then
        if ns.Debug then
            ns.Debug:Warn("CORE", "Cannot recalculate points - profile %s does not exist", profile)
        end
        return
    end
    
    if ns.Debug then
        ns.Debug:Info("CORE", "Starting points recalculation for profile: %s", profile)
    end
    
    -- Reset all points
    profileData.points = {}
    
    -- Get all log entries and convert to sorted array
    local entries = {}
    if profileData.logs then
        for id, entry in pairs(profileData.logs) do
            table.insert(entries, entry)
        end
    end
    
    -- Sort by timestamp (and ID as tiebreaker)
    table.sort(entries, function(a, b)
        if a.timestamp == b.timestamp then
            return a.id < b.id
        end
        return a.timestamp < b.timestamp
    end)
    
    -- Replay all entries to rebuild points
    local entriesProcessed = 0
    local charactersAffected = {}
    
    for _, entry in ipairs(entries) do
        -- Validate entry has target
        if not entry.target then
            if ns.Debug then
                ns.Debug:Error("CORE", "Skipping malformed log entry (ID: %s) - missing target", 
                    tostring(entry.id))
            end
        else
            -- Ensure character entry exists in points
            if not profileData.points[entry.target] then
                profileData.points[entry.target] = {}
            end
            
            -- Set total from the log entry
            profileData.points[entry.target].total = entry.newTotal
            profileData.points[entry.target].lastUpdated = entry.timestamp
            
            -- Track this character
            charactersAffected[entry.target] = true
            entriesProcessed = entriesProcessed + 1
        end
    end
    
    -- Count distinct characters
    local distinctChars = 0
    for _ in pairs(charactersAffected) do
        distinctChars = distinctChars + 1
    end
    
    if ns.Debug then
        ns.Debug:Info("CORE", 
            "Points recalculation complete: %d entries processed, %d characters affected, profile: %s",
            entriesProcessed, distinctChars, profile)
    end
    
    -- Fire callback/event for UI updates
    -- For now, we'll add a simple flag that other modules can check
    -- In future, could implement a proper callback system
    if ns.UI and ns.UI.OnPointsRecalculated then
        ns.UI:OnPointsRecalculated(tier)
    end
end

-- OnPlayerLogin: Called when the player logs in
-- This will be expanded in future phases
function Core:OnPlayerLogin()
    -- Initialize database first
    self:InitDatabase()
    
    -- Create event frame for roster updates
    if not self.rosterFrame then
        self.rosterFrame = CreateFrame("Frame")
        self.rosterFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        self.rosterFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        
        self.rosterFrame:SetScript("OnEvent", function(frame, event, ...)
            if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
                Core:RefreshRoster()
            end
        end)
        
        if ns.Debug then
            ns.Debug:Info("ROSTER", "Roster event frame initialized")
        end
    end
    
    -- Initial roster refresh
    self:RefreshRoster()
    
    -- Create UI frame
    if ns.UI and ns.UI.CreateLootPointFrame then
        ns.UI:CreateLootPointFrame()
    end
    
    -- Log to debug system
    if ns.Debug then
        ns.Debug:Info("PLAYER_LOGIN", "SpectrumFederation loaded")
    end
    
    -- Print success message to chat
    print("|cff00ff00Spectrum Federation|r loaded successfully!")
end
