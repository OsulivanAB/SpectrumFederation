-- Grab the namespace
local addonName, SF = ...

-- Helper function to get test members
-- @return: Array of test member data
function SF:GetTestMembers()
    -- TODO: Expand test data with more varied members for thorough testing
    local members = {
        {name = "Tankmaster", realm = "Garona", classFilename = "WARRIOR", points = 0},
        {name = "Holybringer", realm = "Garona", classFilename = "PALADIN", points = 0},
        {name = "Beastlord", realm = "Stormrage", classFilename = "HUNTER", points = 0},
        {name = "Shadowstrike", realm = "Garona", classFilename = "ROGUE", points = 0},
        {name = "Lightweaver", realm = "Stormrage", classFilename = "PRIEST", points = 0},
        {name = "Earthshaker", realm = "Garona", classFilename = "SHAMAN", points = 0},
        {name = "Frostcaller", realm = "Stormrage", classFilename = "MAGE", points = 0},
        {name = "Soulreaper", realm = "Garona", classFilename = "WARLOCK", points = 0},
        {name = "Brewmaster", realm = "Stormrage", classFilename = "MONK", points = 0},
        {name = "Wildheart", realm = "Garona", classFilename = "DRUID", points = 0},
        {name = "Chaosreaver", realm = "Stormrage", classFilename = "DEMONHUNTER", points = 0},
        {name = "Frostblade", realm = "Garona", classFilename = "DEATHKNIGHT", points = 0},
        {name = "Dreamweaver", realm = "Stormrage", classFilename = "EVOKER", points = 0},
        {name = "Shieldbash", realm = "Garona", classFilename = "WARRIOR", points = 0},
        {name = "Arcanewiz", realm = "Stormrage", classFilename = "MAGE", points = 0},
    }
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Generated %d test members", #members)
    end
    
    return members
end

-- Helper function to get raid members
-- @return: Array of raid member data
function SF:GetRaidMembers()
    local members = {}
    local numMembers = GetNumGroupMembers()
    
    for i = 1, numMembers do
        local name, _, _, _, classFilename, _, _, _, _, _, _ = GetRaidRosterInfo(i)
        if name then
            -- GetRaidRosterInfo returns name without realm, need to get realm separately
            local unitToken = "raid" .. i
            local fullName = UnitName(unitToken)
            local realm = GetRealmName()
            
            -- If name has a realm attached (from another server), parse it
            if fullName and fullName:find("-") then
                local namePart, realmPart = fullName:match("^(.+)-(.+)$")
                if namePart and realmPart then
                    name = namePart
                    realm = realmPart
                end
            end
            
            table.insert(members, {
                name = name,
                realm = realm,
                classFilename = classFilename,
                points = 0  -- TODO: Load from database when points system implemented
            })
        end
    end
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Found %d raid members", #members)
    end
    
    return members
end

-- Helper function to get party members (including player)
-- @return: Array of party member data
function SF:GetPartyMembers()
    local members = {}
    
    -- Add player first
    local playerName = UnitName("player")
    local _, playerClass = UnitClass("player")
    local playerRealm = GetRealmName()
    
    table.insert(members, {
        name = playerName,
        realm = playerRealm,
        classFilename = playerClass,
        points = 0  -- TODO: Load from database
    })
    
    -- Add party members
    local numParty = GetNumSubgroupMembers()
    for i = 1, numParty do
        local unitToken = "party" .. i
        if UnitExists(unitToken) then
            local fullName = UnitName(unitToken)
            local _, classFilename = UnitClass(unitToken)
            local name = fullName
            local realm = GetRealmName()
            
            -- If name has a realm attached (from another server), parse it
            if fullName and fullName:find("-") then
                local namePart, realmPart = fullName:match("^(.+)-(.+)$")
                if namePart and realmPart then
                    name = namePart
                    realm = realmPart
                end
            end
            
            table.insert(members, {
                name = name,
                realm = realm,
                classFilename = classFilename,
                points = 0  -- TODO: Load from database
            })
        end
    end
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Found %d party members (including player)", #members)
    end
    
    return members
end

-- Helper function to get solo player data
-- @return: Array with single player member data
function SF:GetSoloPlayer()
    local playerName = UnitName("player")
    local _, playerClass = UnitClass("player")
    local playerRealm = GetRealmName()
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Solo mode: showing player only")
    end
    
    return {
        {
            name = playerName,
            realm = playerRealm,
            classFilename = playerClass,
            points = 0  -- TODO: Load from database
        }
    }
end
