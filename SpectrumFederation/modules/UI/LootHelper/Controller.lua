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
        self:RequestRefresh("Shown")
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

function Controller:OnEvent(event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        self:EvaluateVisibility("Event:PLAYER_ENTERING_WORLD")
        return
    end

    if event == "GROUP_ROSTER_UPDATE" then
        self:EvaluateVisibility("Event:GROUP_ROSTER_UPDATE")
        return
    end
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
            self:ApplyLockState()
            return
        end

        if path == "lootHelper.showMembersNotInRaid" then
            self:RequestRefresh("SettingsChanged:" .. path)
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

function Controller:_HookProfileMutators()
    if self._hookedProfileMutators then return end

    local LP = SF.LootProfile
    if type(LP) ~= "table" then
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if self and self._inited then
                    self:_HookProfileMutators()
                end
            end)
        end
        return
    end

    local ctrl = self

    local function HookMethod(methodName)
        if type(LP[methodName]) ~= "function" then return end

        hooksecurefunc(LP, methodName, function(profileSelf, ...)
            ctrl:_OnProfileMutated(profileSelf, HookMethod)
        end)
    end

    HookMethod("SetProfileName")
    HookMethod("SetPointName")

    self._hookedProfileMutators = true
end

function Controller:_OnProfileMutated(profileSelf, source)
    local active = SF.GetActiveProfile and SF:GetActiveProfile() or nil
    if not active or active ~= profileSelf then
        return
    end

    self:RefreshTitle()
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
    self:_InitRosterView(frame)
    local events = SF.LootHelperEvents
    if events and events.InitDataHooks then
        events:InitDataHooks()
    end
    self:_BindLootHelperEvents()

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
    self:_HookProfileMutators()

    -- self:RefreshTitle()
    self:ApplyStyle()

    self:ApplyLockState()

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
        if p then
           local profName = (p.GetProfileName and p:GetProfileName()) or "Unnamed Profile"

           local pointsName = "Points"
           if p.GetPointName then
            local v = p:GetPointName()
            v = tostring(v or ""):match("^%s*(.-)%s*$")  -- trim
            if v ~= "" then
                pointsName = v
            end
           end
           titleText = ("%s - %s"):format(profName, pointsName)
        end
    end

    if LH.Window then
        LH.Window:SetProfileName(titleText)

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

function Controller:ApplyLockState()
    local locked = false

    if SF.SettingsStore and SF.SettingsStore.Get then
        locked = SF.SettingsStore:Get("lootHelper.lockLootWindow") and true or false
    else
        local db = SF.lootHelperDB or (SpectrumFederationDB and SpectrumFederationDB.lootHelper)
        locked = db and db.lockLootWindow and true or false
    end

    if LH.Window and LH.Window.SetLocked then
        LH.Window:SetLocked(locked)
    end
end

function Controller:_InitRosterView(frame)
    if self._rosterView then return end
    if not (LH.RosterView and LH.RosterView.new) then return end
    if not frame or not frame.Content then return end

    -- Hide any old placeholder
    if frame.Content.Placeholder then
        frame.Content.Placeholder:Hide()
    end

    self._rosterView = LH.RosterView.new(frame.Content, self)
    frame.Content.RosterView = self._rosterView -- so Style.lua can reach it
end

function Controller:RefreshRoster()
    local f = self:GetFrame()
    if not f then return end

    -- Don't do heavy work if hidden
    if not f:IsShown() then return end

    local profile = SF.GetActiveProfile and SF:GetActiveProfile() or nil
    local rows, meta = LH.RosterModel:Build(profile)

    if self._rosterView then
        self._rosterView:Render(rows, meta)
    end
end

function Controller:RequestRefresh(reason)
    if self._refreshScheduled then return end
    self._refreshScheduled = true

    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            self._refreshScheduled = false
            self:RefreshTitle()
            self:ApplyStyle()
            self:RefreshRoster()
        end)
    else
        self._refreshScheduled = false
        self:RefreshTitle()
        self:ApplyStyle()
        self:RefreshRoster()
    end
end

function Controller:_BindLootHelperEvents()
    if self._boundLHEvents then return end
    local E = SF.LootHelperEvents
    if not E or not E.Register then return end

    E:Register("DATA_CHANGED", function(owner, eventName, reason, payload)
        owner:RequestRefresh("DATA_CHANGED:" .. tostring(reason))
    end, self)

    self._boundLHEvents = true
end