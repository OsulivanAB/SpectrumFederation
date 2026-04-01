-- Grab the namespace
local addonName, SF = ...

SF.SettingsApply = SF.SettingsApply or {}
local Apply = SF.SettingsApply

local PRESS_AND_HOLD_CVAR = "ActionButtonUseKeyDown"

local function GetCurrentSpecializationInfo()
    if not GetSpecialization or not GetSpecializationInfo then
        return nil, nil
    end

    local specIndex = GetSpecialization()
    if not specIndex then
        return nil, nil
    end

    local specID, specName = GetSpecializationInfo(specIndex)
    return specID, specName
end

local function GetPressAndHoldCastingCVarEnabled()
    if GetCVarBool then
        return GetCVarBool(PRESS_AND_HOLD_CVAR) and true or false
    end
    if GetCVar then
        return tostring(GetCVar(PRESS_AND_HOLD_CVAR)) == "1"
    end
    return false
end

-- Initialize the SettingsApply module and register callbacks
-- @return nil
function Apply:Init()
    if self.initialized then return end
    self.initialized = true

    if SF.Debug then
        SF.Debug:Info("SETTINGS", "Initializing SettingsApply module")
    end

    self:InitEventHandling()

    local store = SF.SettingsStore
    if not store or not store.RegisterCallback then return end

    -- Global UI settings
    store:RegisterCallback("global.windowStyle", function(newValue)
        self:Debounce("windowStyle", 0.08, function()
            self:RunOrDefer(function()
                self:ApplyWindowStyle(newValue)
            end)
        end)
    end)

    store:RegisterCallback("global.fontStyle", function(newValue)
        self:Debounce("fontStyle", 0.05, function()
            self:RunOrDefer(function()
                self:ApplyFontStyle(newValue)
            end)
        end)
    end)

    store:RegisterCallback("global.fontSize", function(newValue)
        self:Debounce("fontSize", 0.05, function()
            self:RunOrDefer(function()
                self:ApplyFontSize(newValue)
            end)
        end)
    end)

    store:RegisterCallback("lootHelper.enabled", function(newValue)
        self:Debounce("lootHelperEnabled", 0.1, function()
            self:RunOrDefer(function()
                self:ApplyLootHelperEnabled(newValue)
            end)
        end)
    end)

    store:RegisterCallback("lootHelper.activeProfile", function(newValue, oldValue)
        self:Debounce("activeProfileChange", 0.1, function()
            self:RunOrDefer(function()
                self:ApplyActiveProfileChange(newValue, oldValue)
            end)
        end)
    end)

    store:RegisterCallback("lootHelper.profile.safeMode", function(newValue, oldValue, path, ctx)
        self:Debounce("safeModeChange", 0.1, function()
            self:RunOrDefer(function()
                self:ApplySafeMode(newValue, oldValue, ctx)
            end)
        end)
    end)

    store:RegisterCallback("sf.reset", function()
        self:Debounce("applyAll", 0.2, function()
            self:RunOrDefer(function()
                self:ApplyAll()
            end)
        end)
    end)

    -- Apply current values once at startup
    self:ApplyAll()

    if SF.Debug then
        SF.Debug:Info("SETTINGS", "SettingsApply module initialized and settings applied")
    end
end

-- Debounce a function call with a token and delay, cancelling previous pending calls
-- @param token string Unique token to identify the debounced function
-- @param delay number Seconds to wait before executing
-- @param fn function Function to execute after delay
-- @return nil
function Apply:Debounce(token, delay, fn)
    self._debounce = self._debounce or {}

    -- Cancel an existing timer if possible
    local existing = self._debounce[token]
    if existing and existing.Cancel then
        existing:Cancel()
    end

    if C_Timer and C_Timer.NewTimer then
        self._debounce[token] = C_Timer.NewTimer(delay, fn)
    elseif C_Timer and C_Timer.After then
        C_Timer.After(delay, fn)
    else
        fn()
    end
end

-- Execute a function immediately or defer it until out of combat
-- @param fn function Function to execute
-- @return nil
function Apply:RunOrDefer(fn)
    if InCombatLockdown and InCombatLockdown() then
        self._combatQueue = self._combatQueue or {}
        table.insert(self._combatQueue, fn)

        if not self._combatFrame then
            local f = CreateFrame("Frame")
            self._combatFrame = f
            f:RegisterEvent("PLAYER_REGEN_ENABLED")
            f:SetScript("OnEvent", function()
                f:UnregisterEvent("PLAYER_REGEN_ENABLED")

                local queue = self._combatQueue or {}
                self._combatQueue = {}

                for _, job in ipairs(queue) do
                    pcall(job)
                end
            end)
        else
            self._combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        end

        return
    end

    fn()
end

-- Apply all current settings from store to the game
-- @return nil
function Apply:ApplyAll()
    if SF.Debug then
        SF.Debug:Verbose("SETTINGS", "Applying all settings")
    end

    local store = SF.SettingsStore
    if not store then return end

    self:ApplyWindowStyle(store:Get("global.windowStyle"))
    self:ApplyFontStyle(store:Get("global.fontStyle"))
    self:ApplyFontSize(store:Get("global.fontSize"))

    self:ApplyLootHelperEnabled(store:Get("lootHelper.enabled"))
    self:ApplyActiveProfileChange(store:Get("lootHelper.activeProfile"), nil)
    self:ApplyPressAndHoldCastingForCurrentSpec()

    self:ApplySafeMode(store:GetActiveProfileSetting("safeMode", false), nil, {
        profileName = store:GetActiveProfileName(),
        key = "safeMode",
    })
end

-- Register player event handling needed for settings that depend on runtime state
-- @return nil
function Apply:InitEventHandling()
    if self._eventFrame then return end

    local frame = CreateFrame("Frame")
    self._eventFrame = frame

    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    frame:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)
end

-- Handle runtime events that should re-apply settings
-- @param event string Event name
-- @param ... any Event payload
-- @return nil
function Apply:OnEvent(event, ...)
    if event == "PLAYER_LOGIN" then
        local currentValue = GetPressAndHoldCastingCVarEnabled()
        if SF.SettingsStore and SF.SettingsStore.EnsurePressAndHoldCastingDefaultsForPlayer then
            SF.SettingsStore:EnsurePressAndHoldCastingDefaultsForPlayer(currentValue)
        end
        self:RunOrDefer(function()
            self:ApplyPressAndHoldCastingForCurrentSpec()
        end)
        return
    end

    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        if unit and unit ~= "player" then
            return
        end

        self:RunOrDefer(function()
            self:ApplyPressAndHoldCastingForCurrentSpec()
        end)
    end
end

-- Apply window style setting
-- @param value string Window style value to apply
-- @return nil
function Apply:ApplyWindowStyle(value)
    if SF.Debug then
        SF.Debug:Verbose("SETTINGS", "Applying window style: %s", tostring(value))
    end
    
    -- Trigger LootHelper window style update if the controller exists
    if SF.LootHelperController and SF.LootHelperController.ApplyStyle then
        SF.LootHelperController:ApplyStyle()
    end
end

-- Apply font style setting
-- @param value string Font style value to apply
-- @return nil
function Apply:ApplyFontStyle(value)
    if SF.Debug then
        SF.Debug:Verbose("SETTINGS", "Applying font style: %s", tostring(value))
    end
    -- TODO: implement
end

-- Apply font size setting
-- @param value number Font size value to apply
-- @return nil
function Apply:ApplyFontSize(value)
    if SF.Debug then
        SF.Debug:Verbose("SETTINGS", "Applying font size: %s", tostring(value))
    end
    -- TODO: implement
end

-- Apply loot helper enabled/disabled state
-- @param enabled boolean Whether loot helper is enabled
-- @return nil
function Apply:ApplyLootHelperEnabled(enabled)
    if SF.Debug then
        SF.Debug:Info("SETTINGS", "LootHelper enabled: %s", tostring(enabled))
    end
    -- TODO: implement
end

-- Apply active profile change
-- @param newProfile string|nil Name of new active profile
-- @param oldProfile string|nil Name of previous active profile
-- @return nil
function Apply:ApplyActiveProfileChange(newProfile, oldProfile)
    if SF.Debug then
        SF.Debug:Info("SETTINGS", "Active profile changed from '%s' to '%s'", tostring(oldProfile), tostring(newProfile))
    end
    -- TODO: implement
end

-- Apply safe mode change for a profile
-- @param newValue boolean New safe mode state
-- @param oldValue boolean Previous safe mode state
-- @param ctx table Context table with profileName and key fields
-- @return nil
function Apply:ApplySafeMode(newValue, oldValue, ctx)
    -- ctx.profileName tells you which profile this change applies to
    -- Example: if SF.LootHelper and SF.LootHelper.SetSafeMode then SF.LootHelper:SetSafeMode(ctx.profileName, enabled) end
    if SF.Debug then
        SF.Debug:Info("SETTINGS", "Safe mode changed for profile '%s': %s -> %s", 
            tostring(ctx and ctx.profileName), tostring(oldValue), tostring(newValue))
    end
    -- TODO: implement
end

-- Apply Press and Hold Casting based on the active specialization's saved setting
-- @return nil
function Apply:ApplyPressAndHoldCastingForCurrentSpec()
    local store = SF.SettingsStore
    if not store then return end

    local specID, specName = GetCurrentSpecializationInfo()
    if not specID then
        return
    end

    local enabled = store:GetPressAndHoldCastingBySpec(specID)
    if enabled == nil then
        enabled = GetPressAndHoldCastingCVarEnabled()
        store:SetPressAndHoldCastingBySpec(specID, enabled)
    end

    self:ApplyPressAndHoldCastingForSpec(specID, enabled, specName)
end

-- Apply Press and Hold Casting for a specific specialization
-- @param specID number Specialization ID
-- @param enabled boolean Whether Press and Hold Casting should be enabled
-- @param specName string|nil Specialization display name
-- @return nil
function Apply:ApplyPressAndHoldCastingForSpec(specID, enabled, specName)
    if not specID or enabled == nil or not SetCVar then
        return
    end

    local value = enabled and "1" or "0"
    if GetCVar and tostring(GetCVar(PRESS_AND_HOLD_CVAR)) == value then
        return
    end

    if SF.Debug then
        SF.Debug:Info(
            "SETTINGS",
            "Applying %s=%s for spec '%s' (%s)",
            PRESS_AND_HOLD_CVAR,
            value,
            tostring(specName),
            tostring(specID)
        )
    end

    SetCVar(PRESS_AND_HOLD_CVAR, value)
end
