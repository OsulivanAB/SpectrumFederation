local addonName, ns = ...

-- Local reference to Core module
local Core = ns.Core or {}
ns.Core = Core

-- Roster tracking table - keyed by charKey
Core.roster = {}

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
end

-- GetCurrentTierData: Returns the data table for the current tier
-- @return: Tier data table containing points, logs, and nextLogId
function Core:GetCurrentTierData()
    if not ns.db or not ns.db.tiers or not ns.db.currentTier then
        if ns.Debug then
            ns.Debug:Error("DATABASE", "Cannot get tier data - database not initialized")
        end
        return nil
    end
    
    return ns.db.tiers[ns.db.currentTier]
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
    
    -- Create log entry
    local logEntry = {
        id = tierData.nextLogId,
        timestamp = time(),
        actor = actorCharKey,
        target = charKey,
        delta = delta,
        newTotal = newTotal,
        reason = reason or "Unknown"
    }
    
    -- Add to logs
    tierData.logs[tierData.nextLogId] = logEntry
    tierData.nextLogId = tierData.nextLogId + 1
    
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
    -- Clear existing roster
    self.roster = {}
    
    local inRaid = IsInRaid()
    local inGroup = IsInGroup()
    
    if not inRaid and not inGroup then
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
