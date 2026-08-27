local addonName, ns = ...

-- luacheck: globals SlashCmdList

ns.CST = ns.CST or {}
local CST = ns.CST

local function ParentAddon()
    return _G[CST.PARENT_ADDON_NAME]
end

local function SafeFormat(fmt, ...)
    if type(fmt) ~= "string" then
        return tostring(fmt)
    end
    if select("#", ...) == 0 then
        return fmt
    end
    local ok, out = pcall(string.format, fmt, ...)
    if ok then
        return out
    end
    return fmt
end

local function PrintLine(fmt, ...)
    local line = SafeFormat(fmt, ...)
    local SF = ParentAddon()
    if SF and type(SF.PrintInfo) == "function" then
        SF:PrintInfo(line)
        return
    end
    print("|cff40c7ffSpectrumFederation CST|r: " .. tostring(line))
end

local function Bool(value)
    return value and "true" or "false"
end

local function Stamp(value)
    if not CST.IsFiniteNumber(value) then
        return "nil"
    end
    return tostring(math.floor(value))
end

local function DumpState(state)
    PrintLine("--- Area POI %s ---", tostring(state.areaPoiID))
    PrintLine("  eventID=%s areaPoiID=%s", tostring(state.eventID), tostring(state.areaPoiID))
    PrintLine("  name=%s", tostring(state.name or "nil"))
    PrintLine("  atlas=%s source=%s", tostring(state.atlas or "nil"), tostring(state.atlasSource or "nil"))
    PrintLine("  fixedXY=%.4f,%.4f", tonumber(state.fixedX) or 0, tonumber(state.fixedY) or 0)
    if CST.IsUsableMapPosition(state.liveX, state.liveY) then
        PrintLine("  liveXY=%.4f,%.4f", state.liveX, state.liveY)
    else
        PrintLine("  liveXY=invalid-or-nil")
    end
    PrintLine("  coordinateSource=%s", tostring(state.coordinateSource or "nil"))
    PrintLine(
        "  previous start/end=%s/%s",
        Stamp(state.previous and state.previous.startTime),
        Stamp(state.previous and state.previous.endTime)
    )
    PrintLine(
        "  active start/end=%s/%s",
        Stamp(state.activeOccurrence and state.activeOccurrence.startTime),
        Stamp(state.activeOccurrence and state.activeOccurrence.endTime)
    )
    PrintLine(
        "  next start/end=%s/%s",
        Stamp(state.next and state.next.startTime),
        Stamp(state.next and state.next.endTime)
    )
    PrintLine("  status=%s", tostring(state.status))
    PrintLine("  countdownSeconds=%s", tostring(state.countdownSeconds or "nil"))
    PrintLine("  inactiveRingProgress=%s", tostring(state.ringProgress or "nil"))
    PrintLine("  ringVisible=%s ringMode=%s previousEndSource=%s", Bool(state.ringVisible), tostring(state.ringMode or "nil"), tostring(state.previousEndSource or "nil"))
    PrintLine("  schedulerRowCount=%s", tostring(state.rowCount or 0))
end

local function DumpDiagnostics()
    local Tracker = CST.Tracker
    local MapPins = CST.MapPins
    PrintLine("=== Cursed Surge Tracker diagnostics ===")
    PrintLine("playerOnCoiledIsle=%s trackerInZone=%s", Bool(Tracker and Tracker.IsPlayerOnCoiledIsle and Tracker.IsPlayerOnCoiledIsle()), Bool(Tracker and Tracker.IsInZone and Tracker.IsInZone()))
    PrintLine("displayedWorldMapID=%s", tostring(MapPins and MapPins.GetDisplayedMapID and MapPins.GetDisplayedMapID() or "nil"))
    PrintLine("worldMapVisible=%s providerRegistered=%s", Bool(MapPins and MapPins.IsWorldMapVisible and MapPins.IsWorldMapVisible()), Bool(MapPins and MapPins.IsRegistered and MapPins.IsRegistered()))
    PrintLine("scheduleStatus=%s", tostring(Tracker and Tracker.GetScheduleStatus and Tracker.GetScheduleStatus() or "nil"))
    PrintLine("boundaryTimer=%s tooltipTicker=%s", Bool(Tracker and Tracker.HasBoundaryTimer and Tracker.HasBoundaryTimer()), Bool(Tracker and Tracker.HasTooltipTicker and Tracker.HasTooltipTicker()))

    local states = Tracker and Tracker.GetResolvedStates and Tracker.GetResolvedStates() or {}
    if #states == 0 and CST.ResolveAllLocationStates then
        states = CST.ResolveAllLocationStates({}, nil, "loading", {})
        PrintLine("no live resolved states; showing canonical locations in loading form")
    end
    for index = 1, #states do
        DumpState(states[index])
    end
end

local function HandleSlash(msg)
    msg = tostring(msg or "")
    msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
    msg = string.lower(msg)
    if msg == "" or msg == "debug" or msg == "status" or msg == "dump" then
        DumpDiagnostics()
        return
    end
    if msg == "help" or msg == "?" then
        PrintLine("Cursed Surge Tracker diagnostics:")
        PrintLine("  /sfcst           dump location and timer state")
        PrintLine("  /sf cst          same dump when the parent slash system is available")
        return
    end
    PrintLine("Unknown subcommand '%s'. Use '/sfcst help'.", msg)
end

local installed = false

local function InstallStandaloneSlash()
    if type(SlashCmdList) ~= "table" then
        return
    end
    SLASH_SPECTRUMFEDERATIONCST1 = "/sfcst"
    SLASH_SPECTRUMFEDERATIONCST2 = "/sfcursedsurge"
    SlashCmdList["SPECTRUMFEDERATIONCST"] = function(msg)
        local ok, err = pcall(HandleSlash, msg)
        if not ok then
            PrintLine("Diagnostic command failed: %s", tostring(err))
        end
    end
end

local function InstallParentSlash()
    local SF = ParentAddon()
    if not (SF and SF.RegisterSlashCommand) then
        return
    end
    SF:RegisterSlashCommand("cst", function(args)
        HandleSlash(args)
    end, "Cursed Surge Tracker diagnostics")
end

local function Install()
    if installed then
        return
    end
    installed = true
    InstallStandaloneSlash()
    InstallParentSlash()
end

-- Parent slash commands are registered at PLAYER_LOGIN. Retry then so /sf cst
-- is available without the child depending on parent load-order internals.
InstallStandaloneSlash()

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
    Install()
    self:UnregisterEvent("PLAYER_LOGIN")
end)
