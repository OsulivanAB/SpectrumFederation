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
            -- Also hide equipment window when main window hides
            if LH.EquipmentWindow and LH.EquipmentWindow.Hide then
                LH.EquipmentWindow:Hide()
            end
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
        
        -- Also refresh equipment window if visible
        if LH.EquipmentWindow and LH.EquipmentWindow.IsShown and LH.EquipmentWindow:IsShown() then
            if LH.EquipmentWindow.Refresh then
                LH.EquipmentWindow:Refresh()
            end
        end
    end, self)

    self._boundLHEvents = true
end

-- ===================================================
-- Action Handlers
-- ===================================================

-- Handle adding a raid non-member to the active profile
function Controller:OnAddRaidNonMember(model)
    if not model or not model.memberId then
        if SF.Debug then
            SF.Debug:Warn("LH_WINDOW", "OnAddRaidNonMember: Invalid model provided")
        end
        return
    end

    -- Get active profile
    local profile = SF.GetActiveProfile and SF:GetActiveProfile() or nil
    if not profile then
        if SF.Debug then
            SF.Debug:Warn("LH_WINDOW", "OnAddRaidNonMember: No active profile")
        end
        return
    end

    -- Check admin permissions
    if profile.IsCurrentUserAdmin and not profile:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug:Warn("LH_WINDOW", "OnAddRaidNonMember: User is not admin")
        end
        return
    end

    -- Create member instance
    local memberId = model.memberId
    local className = model.class or "UNKNOWN"

    -- Use existing Member.new constructor
    if not SF.Member or not SF.Member.new then
        if SF.Debug then
            SF.Debug:Error("LH_WINDOW", "OnAddRaidNonMember: SF.Member.new not available")
        end
        return
    end

    local member = SF.Member.new(memberId, SF.MemberRoles.MEMBER, className)
    if not member then
        if SF.Debug then
            SF.Debug:Error("LH_WINDOW", "OnAddRaidNonMember: Failed to create member instance for %s", tostring(memberId))
        end
        return
    end

    -- Add member to profile
    if not profile.AddMember then
        if SF.Debug then
            SF.Debug:Error("LH_WINDOW", "OnAddRaidNonMember: Profile does not support AddMember")
        end
        return
    end

    local ok = profile:AddMember(member)
    if ok then
        -- Notify data changed
        if SF.LootHelperEvents and SF.LootHelperEvents.NotifyDataChanged then
            SF.LootHelperEvents:NotifyDataChanged("UI:AddMember", { memberId = memberId })
        end

        if SF.Debug then
            SF.Debug:Info("LH_WINDOW", "Added member to profile: %s", tostring(memberId))
        end
    else
        if SF.Debug then
            SF.Debug:Warn("LH_WINDOW", "Failed to add member to profile: %s", tostring(memberId))
        end
    end
end

-- Handle equipment button click
function Controller:OnEquipmentClicked(model)
    if not model or model.type ~= "PROFILE_MEMBER" then
        if SF.Debug then
            SF.Debug:Warn("LH_WINDOW", "OnEquipmentClicked: Invalid model or not a profile member")
        end
        return
    end

    -- Get active profile
    local profile = SF.GetActiveProfile and SF:GetActiveProfile() or nil
    if not profile then
        if SF.Debug then
            SF.Debug:Warn("LH_WINDOW", "OnEquipmentClicked: No active profile")
        end
        return
    end

    -- Get member object
    local memberObj = model.member
    if not memberObj and model.memberId then
        -- Try to get member from profile
        if profile.getMemberByID then
            memberObj = profile:getMemberByID(model.memberId)
        elseif profile.GetMemberByID then
            memberObj = profile:GetMemberByID(model.memberId)
        end
    end

    if not memberObj then
        if SF.Debug then
            SF.Debug:Warn("LH_WINDOW", "OnEquipmentClicked: Could not find member object for %s", tostring(model.memberId))
        end
        return
    end

    -- Check admin permissions
    local canAdmin = false
    if profile.IsCurrentUserAdmin then
        canAdmin = profile:IsCurrentUserAdmin() and true or false
    end

    -- Create equipment window if needed
    if LH.EquipmentWindow and LH.EquipmentWindow.Create then
        LH.EquipmentWindow:Create()
    end

    -- Show equipment window
    if LH.EquipmentWindow and LH.EquipmentWindow.ShowForMember then
        local mainFrame = self:GetFrame()
        LH.EquipmentWindow:ShowForMember(mainFrame, model, memberObj, canAdmin)
    end
end