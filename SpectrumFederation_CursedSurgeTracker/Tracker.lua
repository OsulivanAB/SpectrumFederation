local addonName, ns = ...

-- luacheck: globals WorldMapFrame GameTooltip GameTooltip_Hide C_Map C_EventScheduler C_AreaPoiInfo C_Timer GetServerTime GetTime

ns.CST = ns.CST or {}
local CST = ns.CST
local L = ns.L or {}

CST.Tracker = CST.Tracker or {}
local Tracker = CST.Tracker

local inZone = false
local schedulerRegistered = false
local requestedEvents = false
local scheduleStatus = "loading" -- "loading" | "ready"
local cachedRows = {}
local resolvedStates = {}
local extrasByPoi = {}
local boundaryTimer = nil
local tooltipTicker = nil
local hoveredPin = nil
local eventFrame = nil

local function ParentAddon()
    return _G[CST.PARENT_ADDON_NAME]
end

local function DebugInfo(message, ...)
    local SF = ParentAddon()
    if SF and SF.Debug then
        SF.Debug:Info(CST.DEBUG_CATEGORY, message, ...)
    end
end

local function DebugWarn(message, ...)
    local SF = ParentAddon()
    if SF and SF.Debug then
        SF.Debug:Warn(CST.DEBUG_CATEGORY, message, ...)
    end
end

local function Now()
    local SF = ParentAddon()
    if SF and SF.Now then
        return SF:Now()
    end
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function GetParentMapID(mapID)
    if not (C_Map and C_Map.GetMapInfo) then
        return nil
    end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    if not ok or type(info) ~= "table" then
        return nil
    end
    return info.parentMapID
end

local function GetPlayerMapID()
    if not (C_Map and C_Map.GetBestMapForUnit) then
        return nil
    end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok then
        return nil
    end
    return mapID
end

function Tracker.IsPlayerOnCoiledIsle()
    return CST.IsCoiledIsleMap(GetPlayerMapID(), GetParentMapID)
end

function Tracker.ShouldShowPins()
    return CST.ShouldShowPins(inZone, CST.MapPins and CST.MapPins.GetDisplayedMapID and CST.MapPins.GetDisplayedMapID())
end

local function CancelBoundaryTimer()
    if boundaryTimer then
        if boundaryTimer.Cancel then
            boundaryTimer:Cancel()
        end
        boundaryTimer = nil
    end
end

local function HideTooltip()
    if GameTooltip then
        if GameTooltip.Hide then
            GameTooltip:Hide()
        elseif GameTooltip_Hide then
            GameTooltip_Hide()
        end
    end
end

local function CancelTooltipTicker()
    if tooltipTicker then
        if tooltipTicker.Cancel then
            tooltipTicker:Cancel()
        end
        tooltipTicker = nil
    end
    hoveredPin = nil
    HideTooltip()
end

local function TooltipLineForState(state)
    if not state then
        return L["SCHEDULE_UNAVAILABLE"] or "Schedule unavailable"
    end
    if state.status == "loading" then
        return L["LOADING_SCHEDULE"] or "Loading schedule..."
    end
    if state.status == "active" then
        if CST.IsFiniteNumber(state.countdownSeconds) then
            local fmt = L["ACTIVE_ENDS_IN"] or "Active — Ends in %s"
            return string.format(fmt, CST.FormatDuration(state.countdownSeconds))
        end
        return L["ACTIVE"] or "Active"
    end
    if state.status == "inactive" and CST.IsFiniteNumber(state.countdownSeconds) then
        local fmt = L["STARTS_IN"] or "Starts in %s"
        return string.format(fmt, CST.FormatDuration(state.countdownSeconds))
    end
    return L["SCHEDULE_UNAVAILABLE"] or "Schedule unavailable"
end

local function StateForPin(pin)
    if not pin or not pin.cstInfo then
        return nil
    end
    local areaPoiID = pin.cstInfo.areaPoiID
    for index = 1, #resolvedStates do
        local state = resolvedStates[index]
        if state and state.areaPoiID == areaPoiID then
            return state
        end
    end
    return pin.cstInfo
end

local function ShowPinTooltip(pin)
    if not pin or not GameTooltip then
        return
    end
    local state = StateForPin(pin)
    local name = (state and state.name) or L["CURSE_SURGE_FALLBACK_NAME"] or "Curse Surge"
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(name, 1, 1, 1)
    GameTooltip:AddLine(TooltipLineForState(state), 0.9, 0.9, 0.9)
    GameTooltip:Show()
end

local function RefreshHoveredTooltip()
    if not hoveredPin then
        return
    end
    -- Recalculate countdown from absolute timestamps while hovered.
    resolvedStates = CST.ResolveAllLocationStates(cachedRows, Now(), scheduleStatus, extrasByPoi)
    ShowPinTooltip(hoveredPin)
end

function Tracker.OnPinEnter(pin)
    if not Tracker.ShouldShowPins() then
        return
    end
    if hoveredPin == pin and tooltipTicker then
        ShowPinTooltip(pin)
        return
    end
    CancelTooltipTicker()
    hoveredPin = pin
    ShowPinTooltip(pin)
    if C_Timer and C_Timer.NewTicker then
        tooltipTicker = C_Timer.NewTicker(1, function()
            if not hoveredPin then
                CancelTooltipTicker()
                return
            end
            RefreshHoveredTooltip()
        end)
    end
end

function Tracker.OnPinLeave(pin)
    if hoveredPin == pin then
        CancelTooltipTicker()
    end
end

function Tracker.OnPinReleased(pin)
    if hoveredPin == pin then
        CancelTooltipTicker()
    end
end

local function CollectSchedulerRows()
    local rows = {}
    if not C_EventScheduler then
        return rows
    end

    local function Append(list)
        if type(list) ~= "table" then
            return
        end
        for index = 1, #list do
            rows[#rows + 1] = list[index]
        end
    end

    if C_EventScheduler.GetScheduledEvents then
        local ok, scheduled = pcall(C_EventScheduler.GetScheduledEvents)
        if ok then
            Append(scheduled)
        end
    end
    if C_EventScheduler.GetOngoingEvents then
        local ok, ongoing = pcall(C_EventScheduler.GetOngoingEvents)
        if ok then
            Append(ongoing)
        end
    end
    return CST.FilterKnownSchedulerRows(rows)
end

local function LookupPoiInfo(areaPoiID)
    if not (C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIInfo) then
        return nil
    end
    local function Try(mapID)
        local ok, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, areaPoiID)
        if ok and type(info) == "table" then
            return info
        end
        return nil
    end
    return Try(CST.COILED_ISLE_MAP_ID) or Try(nil)
end

local function BuildExtras()
    local extras = {}
    for index = 1, #CST.LOCATIONS do
        local location = CST.LOCATIONS[index]
        local info = LookupPoiInfo(location.areaPoiID)
        local entry = {
            fallbackName = L["CURSE_SURGE_FALLBACK_NAME"],
        }
        if type(info) == "table" then
            entry.name = info.name
            entry.poiAtlas = info.atlasName or info.atlas
            local position = info.position
            if position then
                local x, y
                if position.GetXY then
                    x, y = position:GetXY()
                else
                    x = position.x
                    y = position.y
                end
                entry.liveX = x
                entry.liveY = y
            end
        end
        extras[location.areaPoiID] = entry
    end
    return extras
end

-- ResolveFromCache must be declared before RebuildModel. Lua 5.1 does not
-- see a later `local function` from an earlier local function body.
local function ResolveFromCache()
    resolvedStates = CST.ResolveAllLocationStates(cachedRows, Now(), scheduleStatus, extrasByPoi)
end

local function RebuildModel()
    extrasByPoi = BuildExtras()
    cachedRows = CollectSchedulerRows()
    ResolveFromCache()
end

local function RefreshPinsIfMapVisible()
    local mapVisible = CST.MapPins and CST.MapPins.IsWorldMapVisible and CST.MapPins.IsWorldMapVisible()
    if mapVisible and CST.MapPins and CST.MapPins.Refresh then
        CST.MapPins.Refresh()
    end
end

local ScheduleBoundaryTimer

local function OnBoundaryFired()
    boundaryTimer = nil
    if not inZone then
        return
    end
    RebuildModel()
    if CST.MapPins and CST.MapPins.Refresh then
        CST.MapPins.Refresh()
    end
    if hoveredPin then
        ShowPinTooltip(hoveredPin)
    end
    ScheduleBoundaryTimer()
end

ScheduleBoundaryTimer = function()
    CancelBoundaryTimer()
    local mapVisible = CST.MapPins and CST.MapPins.IsWorldMapVisible and CST.MapPins.IsWorldMapVisible()
    local displayedMapID = CST.MapPins and CST.MapPins.GetDisplayedMapID and CST.MapPins.GetDisplayedMapID()
    if not CST.ShouldRunBoundaryTimer(inZone, mapVisible, displayedMapID) then
        return
    end
    local now = Now()
    local boundary = CST.NextBoundaryTime(resolvedStates, now)
    if not CST.IsFiniteNumber(boundary) then
        return
    end
    local delay = boundary - now
    if delay < 0 then
        delay = 0
    end
    -- Tiny pad so startTime <= now comparisons succeed after the timer fires.
    delay = delay + 0.05
    if C_Timer and C_Timer.NewTimer then
        boundaryTimer = C_Timer.NewTimer(delay, OnBoundaryFired)
    elseif C_Timer and C_Timer.After then
        local token = {}
        boundaryTimer = token
        C_Timer.After(delay, function()
            if boundaryTimer == token then
                OnBoundaryFired()
            end
        end)
        function token:Cancel()
            if boundaryTimer == token then
                boundaryTimer = false
            end
        end
    end
end

function Tracker.OnPinsShown()
    -- Re-derive active/inactive rings from absolute timestamps whenever the
    -- map becomes visible. Do not keep a snapshot from zone entry or from
    -- the last scheduler update while the map was closed.
    ResolveFromCache()
    ScheduleBoundaryTimer()
end

function Tracker.OnPinsHidden()
    CancelBoundaryTimer()
    CancelTooltipTicker()
end

function Tracker.GetPinInfos()
    ResolveFromCache()
    return resolvedStates
end

function Tracker.HasBoundaryTimer()
    return boundaryTimer ~= nil and boundaryTimer ~= false
end

function Tracker.HasTooltipTicker()
    return tooltipTicker ~= nil
end

function Tracker.GetResolvedStates()
    return resolvedStates
end

function Tracker.GetScheduleStatus()
    return scheduleStatus
end

function Tracker.IsInZone()
    return inZone
end

local function UnregisterScheduler()
    if not schedulerRegistered or not eventFrame then
        schedulerRegistered = false
        return
    end
    eventFrame:UnregisterEvent("EVENT_SCHEDULER_UPDATE")
    schedulerRegistered = false
    requestedEvents = false
    cachedRows = {}
    resolvedStates = {}
    extrasByPoi = {}
    scheduleStatus = "loading"
    DebugInfo("Unregistered scheduler processing")
end

local function ConsumeSchedulerData()
    if not inZone then
        return
    end
    local hasData = false
    if C_EventScheduler and C_EventScheduler.HasData then
        local ok, result = pcall(C_EventScheduler.HasData)
        hasData = ok and result and true or false
    end
    if hasData then
        scheduleStatus = "ready"
    end
    RebuildModel()
    -- Cache the latest scheduler rows even while the map is closed. Pin
    -- rendering waits until the World Map is visible; GetPinInfos/OnPinsShown
    -- then re-derive rings from these cached rows and the current timestamp.
    RefreshPinsIfMapVisible()
    if hoveredPin then
        ShowPinTooltip(hoveredPin)
    end
    ScheduleBoundaryTimer()
end

local function RequestSchedulerData()
    if not inZone then
        return
    end
    if C_EventScheduler and C_EventScheduler.HasData then
        local ok, result = pcall(C_EventScheduler.HasData)
        if ok and result then
            scheduleStatus = "ready"
            ConsumeSchedulerData()
            return
        end
    end
    scheduleStatus = "loading"
    RebuildModel()
    RefreshPinsIfMapVisible()
    if requestedEvents then
        return
    end
    if C_EventScheduler and C_EventScheduler.RequestEvents then
        requestedEvents = true
        pcall(C_EventScheduler.RequestEvents)
        DebugInfo("Requested event scheduler data")
    end
end

local function RegisterScheduler()
    if schedulerRegistered or not eventFrame then
        return
    end
    eventFrame:RegisterEvent("EVENT_SCHEDULER_UPDATE")
    schedulerRegistered = true
    DebugInfo("Registered EVENT_SCHEDULER_UPDATE")
end

local function Activate()
    if inZone then
        return
    end
    inZone = true
    DebugInfo("Entered The Coiled Isle (map ancestry of %s)", tostring(CST.COILED_ISLE_MAP_ID))
    RegisterScheduler()
    if CST.MapPins and CST.MapPins.Prepare then
        CST.MapPins.Prepare()
    end
    RequestSchedulerData()
end

local function Deactivate()
    if not inZone then
        CancelBoundaryTimer()
        CancelTooltipTicker()
        return
    end
    inZone = false
    DebugInfo("Left The Coiled Isle; stopping tracker runtime")
    CancelBoundaryTimer()
    CancelTooltipTicker()
    UnregisterScheduler()
    if CST.MapPins and CST.MapPins.Teardown then
        CST.MapPins.Teardown()
    end
end

local function EvaluateZone()
    if Tracker.IsPlayerOnCoiledIsle() then
        if inZone then
            if CST.MapPins and CST.MapPins.IsWorldMapVisible and CST.MapPins.IsWorldMapVisible() and CST.MapPins.Refresh then
                CST.MapPins.Refresh()
            end
        else
            Activate()
        end
    else
        Deactivate()
    end
end

function Tracker.EvaluateZone()
    EvaluateZone()
end

local ZONE_EVENTS = {
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "ZONE_CHANGED",
    "ZONE_CHANGED_INDOORS",
    "ZONE_CHANGED_NEW_AREA",
}

eventFrame = CreateFrame("Frame")
for index = 1, #ZONE_EVENTS do
    eventFrame:RegisterEvent(ZONE_EVENTS[index])
end

eventFrame:SetScript("OnEvent", function(_, event)
    if event == "EVENT_SCHEDULER_UPDATE" then
        if inZone then
            scheduleStatus = "ready"
            ConsumeSchedulerData()
        end
        return
    end
    -- Lightweight zone detection only. Scheduler work happens after Activate.
    EvaluateZone()
end)
