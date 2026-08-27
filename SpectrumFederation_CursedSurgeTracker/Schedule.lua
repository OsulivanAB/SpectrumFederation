local addonName, ns = ...

ns.CST = ns.CST or {}
local CST = ns.CST

local function ToNumber(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        return tonumber(value)
    end
    return nil
end

function CST.IsFiniteNumber(value)
    if type(value) ~= "number" then
        return false
    end
    if value ~= value then
        return false
    end
    if value == math.huge or value == -math.huge then
        return false
    end
    return true
end

-- Accept normalized map coordinates in [0, 1]. Never treat (0, 0) as usable.
function CST.IsUsableMapPosition(x, y)
    if not CST.IsFiniteNumber(x) or not CST.IsFiniteNumber(y) then
        return false
    end
    if x < 0 or x > 1 or y < 0 or y > 1 then
        return false
    end
    if x == 0 and y == 0 then
        return false
    end
    return true
end

-- Prefer a valid live POI position; otherwise keep the documented fixed point.
-- Never replace a known-good fixed coordinate with an invalid API position.
function CST.ResolveCoordinates(fixedX, fixedY, liveX, liveY)
    if CST.IsUsableMapPosition(liveX, liveY) then
        return liveX, liveY, "live"
    end
    if CST.IsUsableMapPosition(fixedX, fixedY) then
        return fixedX, fixedY, "fixed"
    end
    return nil, nil, nil
end

-- Atlas priority:
-- 1. scheduler-provided override
-- 2. AreaPOIInfo.atlasName
-- 3. verified Blizzard atlas UI-EventPoi-venomoustides
-- 4. caller supplies a neutral fallback texture separately when atlas apply fails
function CST.ResolveAtlas(schedulerAtlas, poiAtlas, fallbackAtlas)
    if type(schedulerAtlas) == "string" and schedulerAtlas ~= "" then
        return schedulerAtlas, "scheduler"
    end
    if type(poiAtlas) == "string" and poiAtlas ~= "" then
        return poiAtlas, "poi"
    end
    if type(fallbackAtlas) == "string" and fallbackAtlas ~= "" then
        return fallbackAtlas, "fallback"
    end
    return CST.FALLBACK_ATLAS, "fallback"
end

function CST.Clamp01(value)
    value = ToNumber(value)
    if not CST.IsFiniteNumber(value) then
        return 0
    end
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

-- Walk map ancestry using an injected parent lookup so tests do not need C_Map.
-- Treat mapID as The Coiled Isle when it is 2512 or a descendant of 2512.
function CST.IsMapInAncestry(mapID, targetID, getParentMapID)
    mapID = ToNumber(mapID)
    targetID = ToNumber(targetID)
    if not CST.IsFiniteNumber(mapID) or not CST.IsFiniteNumber(targetID) then
        return false
    end
    if mapID == targetID then
        return true
    end
    if type(getParentMapID) ~= "function" then
        return false
    end

    local seen = {}
    local current = mapID
    local guard = 0
    while current and current ~= 0 and not seen[current] and guard < 32 do
        if current == targetID then
            return true
        end
        seen[current] = true
        current = ToNumber(getParentMapID(current))
        guard = guard + 1
    end
    return current == targetID
end

function CST.IsCoiledIsleMap(mapID, getParentMapID)
    return CST.IsMapInAncestry(mapID, CST.COILED_ISLE_MAP_ID, getParentMapID)
end

function CST.IsKnownAreaPoiID(areaPoiID)
    areaPoiID = ToNumber(areaPoiID)
    return areaPoiID ~= nil and CST.KNOWN_AREA_POI_IDS[areaPoiID] == true
end

function CST.IsKnownEventID(eventID)
    eventID = ToNumber(eventID)
    return eventID ~= nil and CST.KNOWN_EVENT_IDS[eventID] == true
end

function CST.AreaPoiIDForEventID(eventID)
    eventID = ToNumber(eventID)
    if not eventID then
        return nil
    end
    return CST.POI_BY_EVENT_ID[eventID]
end

-- Active duration is endTime - startTime. Never use the scheduler duration field.
function CST.EventDuration(row)
    if type(row) ~= "table" then
        return nil
    end
    local startTime = ToNumber(row.startTime)
    local endTime = ToNumber(row.endTime)
    if not CST.IsFiniteNumber(startTime) or not CST.IsFiniteNumber(endTime) then
        return nil
    end
    local length = endTime - startTime
    if length <= 0 then
        return nil
    end
    return length
end

function CST.IsValidSchedulerRow(row)
    if type(row) ~= "table" then
        return false
    end
    return CST.EventDuration(row) ~= nil
end

-- Match on areaPoiID first. If eventID is present, it must match the canonical
-- mapping for that POI. Rows with only a known eventID still map to that POI.
function CST.RowMatchesLocation(row, location)
    if not CST.IsValidSchedulerRow(row) or type(location) ~= "table" then
        return false
    end

    local rowPoi = ToNumber(row.areaPoiID)
    local rowEvent = ToNumber(row.eventID)
    local expectedPoi = ToNumber(location.areaPoiID)
    local expectedEvent = ToNumber(location.eventID)

    if rowPoi then
        if rowPoi ~= expectedPoi then
            return false
        end
        if rowEvent and expectedEvent and rowEvent ~= expectedEvent then
            return false
        end
        if rowEvent and not expectedEvent and not CST.IsKnownEventID(rowEvent) then
            return false
        end
        return true
    end

    if rowEvent and expectedEvent and rowEvent == expectedEvent then
        return true
    end
    if rowEvent and expectedPoi and CST.AreaPoiIDForEventID(rowEvent) == expectedPoi then
        return true
    end
    return false
end

local function RowIdentity(row)
    return string.format(
        "%s:%s:%s:%s",
        tostring(ToNumber(row.areaPoiID) or ""),
        tostring(ToNumber(row.eventID) or ""),
        tostring(ToNumber(row.startTime) or ""),
        tostring(ToNumber(row.endTime) or "")
    )
end

function CST.DeduplicateRows(rows)
    local result = {}
    if type(rows) ~= "table" then
        return result
    end
    local seen = {}
    for index = 1, #rows do
        local row = rows[index]
        if CST.IsValidSchedulerRow(row) then
            local key = RowIdentity(row)
            if not seen[key] then
                seen[key] = true
                result[#result + 1] = row
            end
        end
    end
    return result
end

function CST.SortRowsByStartTime(rows)
    local result = {}
    if type(rows) ~= "table" then
        return result
    end
    for index = 1, #rows do
        result[index] = rows[index]
    end
    table.sort(result, function(left, right)
        local leftStart = ToNumber(left and left.startTime) or 0
        local rightStart = ToNumber(right and right.startTime) or 0
        if leftStart == rightStart then
            local leftEnd = ToNumber(left and left.endTime) or 0
            local rightEnd = ToNumber(right and right.endTime) or 0
            return leftEnd < rightEnd
        end
        return leftStart < rightStart
    end)
    return result
end

function CST.FilterRowsForLocation(rows, location)
    local matched = {}
    if type(rows) ~= "table" or type(location) ~= "table" then
        return matched
    end
    for index = 1, #rows do
        local row = rows[index]
        if CST.RowMatchesLocation(row, location) then
            matched[#matched + 1] = row
        end
    end
    return CST.SortRowsByStartTime(CST.DeduplicateRows(matched))
end

function CST.FilterKnownSchedulerRows(rows)
    local matched = {}
    if type(rows) ~= "table" then
        return matched
    end
    for index = 1, #rows do
        local row = rows[index]
        if CST.IsValidSchedulerRow(row) then
            local poi = ToNumber(row.areaPoiID)
            local eventID = ToNumber(row.eventID)
            if CST.IsKnownAreaPoiID(poi) or CST.IsKnownEventID(eventID) then
                -- Secondary validation: if eventID is present it must map to this POI.
                if poi and eventID then
                    local expectedPoi = CST.AreaPoiIDForEventID(eventID)
                    if expectedPoi ~= poi then
                        -- skip conflicting or unknown eventID
                    else
                        matched[#matched + 1] = row
                    end
                else
                    matched[#matched + 1] = row
                end
            end
        end
    end
    return CST.SortRowsByStartTime(CST.DeduplicateRows(matched))
end

-- Active when startTime <= now < endTime. Multiple locations may be active.
function CST.IsOccurrenceActive(row, now)
    if not CST.IsValidSchedulerRow(row) then
        return false
    end
    now = ToNumber(now)
    if not CST.IsFiniteNumber(now) then
        return false
    end
    local startTime = ToNumber(row.startTime)
    local endTime = ToNumber(row.endTime)
    return startTime <= now and now < endTime
end

function CST.SelectActiveOccurrence(rows, now)
    if type(rows) ~= "table" then
        return nil
    end
    for index = 1, #rows do
        local row = rows[index]
        if CST.IsOccurrenceActive(row, now) then
            return row
        end
    end
    return nil
end

function CST.SelectNextOccurrence(rows, now)
    now = ToNumber(now)
    if type(rows) ~= "table" or not CST.IsFiniteNumber(now) then
        return nil
    end
    local best = nil
    for index = 1, #rows do
        local row = rows[index]
        local startTime = ToNumber(row and row.startTime)
        if CST.IsFiniteNumber(startTime) and startTime > now then
            if not best or startTime < ToNumber(best.startTime) then
                best = row
            end
        end
    end
    return best
end

-- Most recent completed occurrence: latest endTime that is <= now.
function CST.SelectPreviousOccurrence(rows, now)
    now = ToNumber(now)
    if type(rows) ~= "table" or not CST.IsFiniteNumber(now) then
        return nil
    end
    local best = nil
    for index = 1, #rows do
        local row = rows[index]
        local endTime = ToNumber(row and row.endTime)
        if CST.IsFiniteNumber(endTime) and endTime <= now then
            if not best or endTime > ToNumber(best.endTime) then
                best = row
            end
        end
    end
    return best
end

local function MeasuredStartInterval(rows)
    if type(rows) ~= "table" or #rows < 2 then
        return nil
    end
    local best
    for index = 2, #rows do
        local previous = rows[index - 1]
        local current = rows[index]
        local previousStart = ToNumber(previous and previous.startTime)
        local currentStart = ToNumber(current and current.startTime)
        if CST.IsFiniteNumber(previousStart) and CST.IsFiniteNumber(currentStart) and currentStart > previousStart then
            local interval = currentStart - previousStart
            if not best or interval < best then
                best = interval
            end
        end
    end
    return best
end

local function RepresentativeEventLength(rows, nextOccurrence)
    local length = CST.EventDuration(nextOccurrence)
    if length then
        return length
    end
    if type(rows) ~= "table" then
        return nil
    end
    for index = 1, #rows do
        length = CST.EventDuration(rows[index])
        if length then
            return length
        end
    end
    return nil
end

-- Previous-end priority for inactive ring progress:
-- 1. A prior scheduler row for the same Area POI
-- 2. Consecutive same-location rows plus a schedule-derived event length
-- 3. Verified same-location recurrence (13,500s) as a guarded fallback
-- 4. nil when a trustworthy inactive interval cannot be determined
function CST.ResolvePreviousEndTime(rows, nextOccurrence, now)
    local previous = CST.SelectPreviousOccurrence(rows, now)
    if previous then
        return ToNumber(previous.endTime), "scheduler"
    end

    local nextStart = ToNumber(nextOccurrence and nextOccurrence.startTime)
    if not CST.IsFiniteNumber(nextStart) then
        return nil, nil
    end

    if type(rows) == "table" then
        local prior
        for index = 1, #rows do
            local row = rows[index]
            local startTime = ToNumber(row and row.startTime)
            if CST.IsFiniteNumber(startTime) and startTime < nextStart then
                prior = row
            end
        end
        if prior and CST.IsFiniteNumber(ToNumber(prior.endTime)) then
            return ToNumber(prior.endTime), "scheduler"
        end
    end

    local eventLength = RepresentativeEventLength(rows, nextOccurrence)
    local startInterval = MeasuredStartInterval(rows)
    if CST.IsFiniteNumber(startInterval) and CST.IsFiniteNumber(eventLength) and startInterval > eventLength then
        return nextStart - (startInterval - eventLength), "inferred"
    end

    if CST.IsFiniteNumber(eventLength) and CST.SAME_LOCATION_RECURRENCE_SECONDS > eventLength then
        return nextStart - (CST.SAME_LOCATION_RECURRENCE_SECONDS - eventLength), "recurrence"
    end

    return nil, nil
end

-- Inactive ring: 1 at previousEnd, 0 at nextStart. Hide the ring when nil.
function CST.InactiveRingProgress(previousEndTime, nextStartTime, now)
    previousEndTime = ToNumber(previousEndTime)
    nextStartTime = ToNumber(nextStartTime)
    now = ToNumber(now)
    if not CST.IsFiniteNumber(previousEndTime) or not CST.IsFiniteNumber(nextStartTime) or not CST.IsFiniteNumber(now) then
        return nil
    end
    local span = nextStartTime - previousEndTime
    if span <= 0 then
        return nil
    end
    return CST.Clamp01((nextStartTime - now) / span)
end

function CST.ActiveRingProgress()
    return 1
end

-- Under one hour: MM:SS. One hour or more: H:MM:SS. Always include seconds.
function CST.FormatDuration(seconds)
    seconds = ToNumber(seconds)
    if not CST.IsFiniteNumber(seconds) then
        seconds = 0
    end
    seconds = math.floor(seconds)
    if seconds < 0 then
        seconds = 0
    end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remain = seconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, remain)
    end
    return string.format("%02d:%02d", minutes, remain)
end

function CST.SchedulerAtlasFromRow(row)
    if type(row) ~= "table" then
        return nil
    end
    local atlas = row.atlasName or row.atlas or row.overrideAtlas or row.iconAtlas
    if type(atlas) == "string" and atlas ~= "" then
        return atlas
    end
    return nil
end

function CST.LocalizedNameFromRow(row)
    if type(row) ~= "table" then
        return nil
    end
    local name = row.name or row.eventName or row.title
    if type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

-- scheduleStatus: "loading" | "ready"
-- Returns one resolved state object per canonical location.
function CST.ResolveLocationState(location, rows, now, scheduleStatus, extras)
    extras = extras or {}
    local state = {
        eventID = location and location.eventID or nil,
        areaPoiID = location and location.areaPoiID or nil,
        fixedX = location and location.x or nil,
        fixedY = location and location.y or nil,
        liveX = extras.liveX,
        liveY = extras.liveY,
        x = nil,
        y = nil,
        coordinateSource = nil,
        atlas = nil,
        atlasSource = nil,
        name = extras.name,
        status = "unavailable",
        active = false,
        previous = nil,
        activeOccurrence = nil,
        next = nil,
        previousEndTime = nil,
        previousEndSource = nil,
        countdownSeconds = nil,
        ringProgress = nil,
        ringVisible = false,
        ringMode = nil, -- "active" | "inactive"
        rowCount = 0,
    }

    local x, y, coordinateSource = CST.ResolveCoordinates(
        state.fixedX,
        state.fixedY,
        extras.liveX,
        extras.liveY
    )
    state.x = x
    state.y = y
    state.coordinateSource = coordinateSource

    local filtered = CST.FilterRowsForLocation(rows, location)
    state.rowCount = #filtered

    local schedulerAtlas = extras.schedulerAtlas
    for index = 1, #filtered do
        local row = filtered[index]
        if not schedulerAtlas then
            schedulerAtlas = CST.SchedulerAtlasFromRow(row)
        end
        if not state.name then
            state.name = CST.LocalizedNameFromRow(row)
        end
        if schedulerAtlas and state.name then
            break
        end
    end
    state.atlas, state.atlasSource = CST.ResolveAtlas(
        extras.schedulerAtlas or schedulerAtlas,
        extras.poiAtlas,
        CST.FALLBACK_ATLAS
    )
    if not state.name then
        state.name = extras.fallbackName
    end

    if scheduleStatus == "loading" then
        state.status = "loading"
        return state
    end

    now = ToNumber(now)
    if not CST.IsFiniteNumber(now) then
        state.status = "unavailable"
        return state
    end

    local activeOccurrence = CST.SelectActiveOccurrence(filtered, now)
    local nextOccurrence = CST.SelectNextOccurrence(filtered, now)
    local previousOccurrence = CST.SelectPreviousOccurrence(filtered, now)

    state.activeOccurrence = activeOccurrence
    state.next = nextOccurrence
    state.previous = previousOccurrence

    if activeOccurrence then
        state.status = "active"
        state.active = true
        state.ringVisible = true
        state.ringMode = "active"
        state.ringProgress = CST.ActiveRingProgress()
        local endTime = ToNumber(activeOccurrence.endTime)
        if CST.IsFiniteNumber(endTime) and endTime > now then
            state.countdownSeconds = endTime - now
        end
        return state
    end

    if nextOccurrence then
        state.status = "inactive"
        state.active = false
        local previousEnd, previousSource = CST.ResolvePreviousEndTime(filtered, nextOccurrence, now)
        state.previousEndTime = previousEnd
        state.previousEndSource = previousSource
        local nextStart = ToNumber(nextOccurrence.startTime)
        if CST.IsFiniteNumber(nextStart) and nextStart > now then
            state.countdownSeconds = nextStart - now
        end
        local progress = CST.InactiveRingProgress(previousEnd, nextStart, now)
        if progress ~= nil then
            state.ringVisible = true
            state.ringMode = "inactive"
            state.ringProgress = progress
        end
        return state
    end

    state.status = "unavailable"
    return state
end

function CST.ResolveAllLocationStates(rows, now, scheduleStatus, extrasByPoi)
    extrasByPoi = extrasByPoi or {}
    local states = {}
    for index = 1, #CST.LOCATIONS do
        local location = CST.LOCATIONS[index]
        states[#states + 1] = CST.ResolveLocationState(
            location,
            rows,
            now,
            scheduleStatus,
            extrasByPoi[location.areaPoiID]
        )
    end
    return states
end

-- Nearest start or end boundary across resolved states.
function CST.NextBoundaryTime(states, now)
    now = ToNumber(now)
    if type(states) ~= "table" or not CST.IsFiniteNumber(now) then
        return nil
    end
    local best
    local function consider(timestamp)
        timestamp = ToNumber(timestamp)
        if CST.IsFiniteNumber(timestamp) and timestamp > now then
            if not best or timestamp < best then
                best = timestamp
            end
        end
    end
    for index = 1, #states do
        local state = states[index]
        if state then
            if state.activeOccurrence then
                consider(state.activeOccurrence.endTime)
            end
            if state.next then
                consider(state.next.startTime)
            end
        end
    end
    return best
end

-- Testable runtime policy: what may run in each physical/map situation.
function CST.ShouldProcessScheduler(inZone)
    return inZone == true
end

function CST.ShouldShowPins(inZone, displayedMapID)
    return inZone == true and ToNumber(displayedMapID) == CST.COILED_ISLE_MAP_ID
end

function CST.ShouldRunBoundaryTimer(inZone, mapVisible, displayedMapID)
    return CST.ShouldShowPins(inZone, displayedMapID) and mapVisible == true
end

function CST.ShouldRunTooltipTicker(inZone, mapVisible, displayedMapID, hovering)
    return CST.ShouldShowPins(inZone, displayedMapID) and mapVisible == true and hovering == true
end
