-- Grab the namespace
local addonName, SF = ...

-- Get current player's name and realm
-- @return: playerName (string), realmName (string)
function SF:GetPlayerInfo()
    local name = UnitName("player")
    local realm = GetRealmName()
    if SF.Debug then SF.Debug:Verbose("PROFILES", "Retrieved player info: %s-%s", name, realm) end
    return name, realm
end