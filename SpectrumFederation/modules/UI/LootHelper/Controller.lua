-- modules/UI/LootHelper/Window.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow

LH.Controller = LH.Controller or {}
local Controller = LH.Controller

-- ===================================================================
-- Helpers
-- ===================================================================
local function GetLootDB()
    return SF.lootHelperDB or (SpectrumFederationDB and SpectrumFederationDB.lootHelper) or nil
end

local function IsEnabled()
    local db = GetLootDB()
    return db and db.enabled and true or false
end

local function ShowOutsideRaid()
    local db = GetLootDB()
    return db and db.showWindowOutsideRaid and true or false
end

local function HasActiveProfile()
    if SF.GetActiveProfile then
        return SF:GetActiveProfile() ~= nil
    end

    -- Fallback
    local db = GetLootDB()
    if not db then return false end
    return db.activeProfileId ~= nil and db.profiles and db.profiles[db.activeProfileId] ~= nil
end

-- ===================================================================
-- Core
-- ===================================================================
function Controller:ShouldBeVisible()
    -- Rule 1: enabled must be true
    if not IsEnabled() then
        return false, "disabled"
    end

    -- Rule 2: must have active profile
    if not HasActiveProfile() then
        return false, "no_active_profile"
    end

    -- Rule 3: outside-raid logic
    if IsInRaid() then
        return true, "in_raid"
    end

    if ShowOutsideRaid() then
        return true, "outside_raid_allowed"
    end

    return false, "not_in_raid"
end

function Controller:EvaluateVisibility(reason)
    local f = self:GetFrame()
    if not f then return end

    -- Keep title accurate even if hidden
    self:RefreshTitle()

    local shouldShow, why = self:ShouldBeVisible()

    if shouldShow then
        if not f:IsShown() then
            f:Show()
        end
    else
        if f:IsShown() then
            f:Hide()
        end
    end

    if SF.Debug then
        SF.Debug:Verbose("LH_WINDOW", "EvaluateVisibility(%s): show=%s (%s)", tostring(reason), tostring(shouldShow), tostring(why))
    end
end

-- ===================================================
-- Event Wiring
-- ===================================================
function Controller:_InitEvents()
    if self._eventFrame then return end

    local ef = CreateFrame("Frame")
    self._eventFrame = ef

    ef:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)

    ef:RegisterEvent("PLAYER_ENTERING_WORLD")
    ef:RegisterEvent("GROUP_ROSTER_UPDATE")
end

-- ===================================================
-- Hooks: Settings + active profile
-- ===================================================
function Controller:_HookSettingsStore()
    if self._hookedSettingsStore then return end
    
    local store = SF.SettingsStore
    if not store or type(store.Set) ~= "function" then return end

    self._hookedSettingsStore = true

    -- This fires whenever the Settings UI calls Store:Set("path", value)
    hooksecurefunc(store, "Set", function(_, path, value)
        if type(path) ~= "string" then return end

        if path == "lootHelper.enabled"
            or path == "lootHelper.showWindowOutsideRaid"
            or path == "lootHelper.activeProfileId"
            or path == "lootHelper.activeProfile"
        then
            self:EvaluateVisibility("SettingsChanged:" .. path)
            return
        end

        -- Styling-related settings
        if path == "global.windowStyle"
            or path == "global.fontStyle"
            or path == "global.fontSize"
        then
            self:ApplyStyle()
            return
        end

        if path == "lootHelper.lockLootWindow" then
            return
        end
    end)
end

function Controller:_HookProfileChanges()
    if self._hookedProfile then return end

    if type(SF.SetActiveProfileById) == "function" then
        self._hookedProfile = true
        hooksecurefunc(SF, "SetActiveProfileById", function(_, profileId)
            self:OnActiveProfileChanged(profileId)
        end)
    end
end

function Controller:OnActiveProfileChanged(profileId)
    self:RefreshTitle()
    self:EvaluateVisibility("ActiveProfileChanged")
end

-- TODO: Could we create a hook for profile point changes?

-- ===================================================
-- Public API
-- ===================================================
function Controller:Init()
    if self._inited then return end
    self._inited = true

    local frame = LH.Window:Create()
    -- frame:Hide()

    -- Wire title bar buttons
    frame.OnGearClicked = function()
        self:OpenSettings()
    end

    frame.OnCloseClicked = function()
        self:OnCloseClicked()
    end

    self:_InitEvents()
    self:_HookSettingsStore()
    self:_HookProfileChanges()

    -- self:RefreshTitle()
    self:ApplyStyle()

    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            self:EvaluateVisibility("InitDeferred")
        end)
    else
        self:EvaluateVisibility("InitImmediate")
    end
end

-- Get the Loot Helper main frame
-- @return Frame|nil Main frame or nil if not created
function Controller:GetFrame()
    return LH.Window and LH.Window:GetFrame() or nil
end

function Controller:ApplyStyle()
    local f = self:GetFrame()
    if not f then return end
    if LH.Style and LH.Style.Apply then
        LH.Style:Apply(f)
    end
end

-- Refresh the title bar information
function Controller:RefreshTitle()
    local profileName = "No Active Profile"
    if SF.GetActiveProfile then
        local p = SF:GetActiveProfile()
        if p and p.GetProfileName then
            profileName = p:GetProfileName()
        end
    end

    if LH.Window then
        LH.Window:SetProfileName(profileName)

        -- TODO: session system later (always false for now)
        LH.Window:SetSessionActive(false)
    end
end

-- Handle OpenSettings action
function Controller:OpenSettings()
    if SF.SettingsUI and SF.SettingsUI.OpenToPage then
        SF.SettingsUI:OpenToPage("loothelper")
        return
    end

    -- Fallback Message
    print("SpectrumFederation: Open Settings → AddOns → Spectrum Federation Settings → Loot Helper Settings")
end

function Controller:OnCloseClicked()
    if SF.SettingsStore and SF.SettingsStore.Set then
        SF.SettingsStore:Set("lootHelper.enabled", false)
    else
        local db = GetLootDB()
        if db then db.enabled = false end
    end

    self:EvaluateVisibility("CloseClicked")
end

-- TODO: Temporary to verify skeleton exists
function Controller:ShowDebug()
    self:Init()
    self:EvaluateVisibility("ShowDebug")
end