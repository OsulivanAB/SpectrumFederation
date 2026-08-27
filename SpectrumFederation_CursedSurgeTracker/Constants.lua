local addonName, ns = ...

-- Cursed Surge Tracker constants verified from the live retail client.
-- Map identity is uiMapID 2512 (The Coiled Isle). Do not key runtime logic
-- on the English zone name.

ns.CST = ns.CST or {}
local CST = ns.CST

CST.ADDON_NAME = addonName
CST.PARENT_ADDON_NAME = "SpectrumFederation"
CST.DEBUG_CATEGORY = "CST"

-- Physical zone / displayed map
CST.COILED_ISLE_MAP_ID = 2512

-- Verified Blizzard atlas for Curse Surge events
CST.FALLBACK_ATLAS = "UI-EventPoi-venomoustides"

-- Last-resort icon if no atlas can be applied
CST.NEUTRAL_FALLBACK_TEXTURE = "Interface\\Buttons\\WHITE8X8"

-- Ring art owned by this child addon (annular swipe / static active ring)
CST.RING_TEXTURE = "Interface\\AddOns\\SpectrumFederation_CursedSurgeTracker\\media\\ring"

-- Documented cadence from live observation. Live scheduler timestamps remain
-- the timing authority whenever valid rows exist.
-- A new location starts every 2,700 seconds (45 minutes).
CST.LOCATION_STEP_SECONDS = 2700
-- The same location repeats every 13,500 seconds (3 hours 45 minutes).
CST.SAME_LOCATION_RECURRENCE_SECONDS = 13500
-- Verified rotation of Area POI IDs:
-- 8939 -> 8937 -> 8940 -> 8938 -> 8936 -> repeat
CST.ROTATION_AREA_POI_IDS = { 8939, 8937, 8940, 8938, 8936 }

-- Pin layout in logical pixels. Ring sits outside the icon.
CST.PIN_SIZE = 36
CST.RING_SIZE = 32
CST.ICON_SIZE = 22

CST.RING_COLOR_ACTIVE = { r = 1.00, g = 0.12, b = 0.12, a = 1.0 }
CST.RING_COLOR_INACTIVE = { r = 0.15, g = 1.00, b = 0.28, a = 1.0 }

-- Canonical Curse Surge locations. areaPoiID is the primary runtime identifier.
-- eventID is secondary validation. Coordinates are normalized map positions
-- verified live because C_AreaPoiInfo often returns (0, 0) or nil.
CST.LOCATIONS = {
    { eventID = 42, areaPoiID = 8936, x = 0.2662, y = 0.6490 },
    { eventID = 43, areaPoiID = 8940, x = 0.4720, y = 0.6205 },
    { eventID = 44, areaPoiID = 8939, x = 0.7098, y = 0.3191 },
    { eventID = 45, areaPoiID = 8938, x = 0.4535, y = 0.2862 },
    { eventID = 46, areaPoiID = 8937, x = 0.6747, y = 0.7789 },
}

CST.LOCATIONS_BY_POI = {}
CST.POI_BY_EVENT_ID = {}
CST.KNOWN_AREA_POI_IDS = {}
CST.KNOWN_EVENT_IDS = {}

for index = 1, #CST.LOCATIONS do
    local location = CST.LOCATIONS[index]
    CST.LOCATIONS_BY_POI[location.areaPoiID] = location
    CST.POI_BY_EVENT_ID[location.eventID] = location.areaPoiID
    CST.KNOWN_AREA_POI_IDS[location.areaPoiID] = true
    CST.KNOWN_EVENT_IDS[location.eventID] = true
end
