-- Grab the namespace
local addonName, SF = ...

SF.SettingsApply = SF.SettingsApply or {}
local Apply = SF.SettingsApply

-- Initialize the SettingsApply module and register callbacks
-- @return nil
function Apply:Init()
    if self.initialized then return end
    self.initialized = true

    if SF.Debug then
        SF.Debug:Info("SETTINGS", "Initializing SettingsApply module")
    end

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

    self:ApplySafeMode(store:GetActiveProfileSetting("safeMode", false), nil, {
        profileName = store:GetActiveProfileName(),
        key = "safeMode",
    })
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