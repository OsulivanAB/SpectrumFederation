-- Grab the namespace
local addonName, SF = ...

SF.SettingsApply = SF.SettingsApply or {}
local Apply = SF.SettingsApply

function Apply:Init()
    if self.initialized then return end
    self.initialized = true

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
end

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

function Apply:ApplyAll()
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

function Apply:ApplyWindowStyle(value)
    -- TODO: implement
end

function Apply:ApplyFontStyle(value)
    -- TODO: implement
end

function Apply:ApplyFontSize(value)
    -- TODO: implement
end

function Apply:ApplyLootHelperEnabled(enabled)
    -- TODO: implement
end

function Apply:ApplyActiveProfileChange(newProfile, oldProfile)
    -- TODO: implement
end

function Apply:ApplySafeMode(newValue, oldValue, ctx)
    -- ctx.profileName tells you which profile this change applies to
    -- Example: if SF.LootHelper and SF.LootHelper.SetSafeMode then SF.LootHelper:SetSafeMode(ctx.profileName, enabled) end
    -- TODO: implement
end