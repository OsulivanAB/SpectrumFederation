-- Grab the namespace
local addonName, SF = ...

-- Helper Function to get the current player's info
local function GetPlayerInfo()
    local name = UnitName("player")
    local realm = GetRealmName()
    if SF.Debug then SF.Debug:Verbose("PROFILES", "Retrieved player info: %s-%s", name, realm) end
    return name, realm
end

-- CREATE: Add a new profile
function SF:CreateNewLootProfile(profileName)

    -- Input Validation
    if type(profileName) ~= "string" or profileName == "" then
        if SF.Debug then SF.Debug:Warn("PROFILES", "CreateNewLootProfile failed: Invalid profile name") end
        print("|cFFFF0000" .. addonName .. "|r: Invalid profile name.")
        return
    end

    -- Check if profile already exists
    if self.db.lootProfiles[profileName] then
        if SF.Debug then SF.Debug:Warn("PROFILES", "CreateNewLootProfile failed: Profile '%s' already exists", profileName) end
        print("|cFFFF0000" .. addonName .. "|r: Profile '" .. profileName .. "' already exists.")
        return
    end

    -- Construct the Profile Object
    local playerName, realmName = GetPlayerInfo()
    local adminKey = playerName .. "-" .. realmName

    local newProfile = {
        name = profileName,
        owner = playerName,
        server = realmName,
        admins = { adminKey },
        created = time(),
        modified = time()
    }

    -- Save the new profile to the database
    self.db.lootProfiles[profileName] = newProfile
    if SF.Debug then SF.Debug:Info("PROFILES", "Created new profile '%s' with owner %s", profileName, adminKey) end
    print("|cFF00FF00" .. addonName .. "|r: Profile '" .. profileName .. "' created successfully.")

    -- Auto-set the new profile as active
    SF:SetActiveLootProfile(profileName)

end

-- UPDATE: Set the active profile
function SF:SetActiveLootProfile(profileName)

    -- Input Validation
    if not self.db.lootProfiles[profileName] then
        if SF.Debug then SF.Debug:Warn("PROFILES", "SetActiveLootProfile failed: Profile '%s' does not exist", profileName) end
        print("|cFFFF0000" .. addonName .. "|r: Profile '" .. profileName .. "' does not exist.")
        return
    end

    -- Set the active profile
    self.db.activeLootProfile = profileName
    if SF.Debug then SF.Debug:Info("PROFILES", "Set active profile to '%s'", profileName) end
    print("|cFF00FF00" .. addonName .. "|r: Active profile set to '" .. profileName .. "'.")

    -- Update the UI dropdown to match
    if SF.UpdateLootProfileDropdownText then
        SF:UpdateLootProfileDropdownText()
    else
        if SF.Debug then SF.Debug:Warn("UI", "UpdateLootProfileDropdownText function not found") end
        print("|cFFFFA500" .. addonName .. "|r: Warning - UI dropdown update function not found.")
    end
end

-- DELETE: Remove a profile
function SF:DeleteProfile(profileName)

    if self.db.lootProfiles[profileName] then

        -- Remove the profile from the database
        self.db.lootProfiles[profileName] = nil
        if SF.Debug then SF.Debug:Info("PROFILES", "Deleted profile '%s'", profileName) end
        print("|cFF00FF00" .. addonName .. "|r: Profile '" .. profileName .. "' deleted successfully.")

        -- If the deleted profile was active, clear the active profile
        if self.db.activeLootProfile == profileName then
            self.db.activeLootProfile = nil
            if SF.Debug then SF.Debug:Info("PROFILES", "Cleared active profile as it was deleted") end
            print("|cFFFFA500" .. addonName .. "|r: Active profile cleared as it was deleted.")
        end

    else

        if SF.Debug then SF.Debug:Warn("PROFILES", "DeleteProfile failed: Profile '%s' does not exist", profileName) end
        print("|cFFFF0000" .. addonName .. "|r: Profile '" .. profileName .. "' does not exist.")

    end

end