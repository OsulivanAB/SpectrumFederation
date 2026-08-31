-- Production-Lua tests for MouseTracer Constants + TrailEngine.
-- Run from the repository root: lua5.1 tests/lua/mouse_tracer_tests.lua

local function repoPath(relative)
    return relative
end

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. message .. "\n")
end

local function assertTrue(cond, message)
    if cond then
        pass(message)
    else
        fail(message)
    end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assertAlmost(actual, expected, epsilon, message)
    if type(actual) ~= "number" or type(expected) ~= "number" then
        fail(message .. " (non-numeric)")
        return
    end
    if math.abs(actual - expected) <= epsilon then
        pass(message)
    else
        fail(string.format("%s (expected %s ± %s, got %s)", message, tostring(expected), tostring(epsilon), tostring(actual)))
    end
end

local SF = {}
local constChunk = assert(loadfile(repoPath("SpectrumFederation/modules/MouseTracer/Constants.lua")))
constChunk("SpectrumFederation", SF)
local engineChunk = assert(loadfile(repoPath("SpectrumFederation/modules/MouseTracer/TrailEngine.lua")))
engineChunk("SpectrumFederation", SF)

local C = SF.MouseTracer.Constants
local Engine = SF.MouseTracer.TrailEngine

assertEq(C.DEFAULT_TRAIL_LENGTH, 400, "default trail length is 400")
assertAlmost(C.DEFAULT_FADE_DURATION, 0.50, 1e-9, "default fade duration is 0.5")
assertEq(C.DEFAULT_THICKNESS, 16, "default trail thickness is 16")
assertAlmost(C.DEFAULT_RAINBOW_SPEED, 0.25, 1e-9, "default rainbow speed is 0.25")
assertAlmost(C.DEFAULT_OPACITY, 0.70, 1e-9, "default trail opacity is 0.7")
assertEq(C.MAX_TRAIL_LENGTH, 1200, "maximum trail length is 1200")
assertEq(C.MIN_TRAIL_LENGTH, 80, "minimum trail length stays 80")
assertAlmost(C.TAPER_MIN_RATIO, 0.40, 1e-9, "oldest stamp is 40% of configured thickness")
assertEq(C.MAX_POINTS, 1202, "MAX_POINTS is derived from 1200/1 + 2")
assertEq(C.MAX_SEGMENTS, 1201, "MAX_SEGMENTS is MAX_POINTS - 1")
assertEq(C.MAX_NEW_POINTS_PER_TICK, 250, "emit cap covers a non-teleport move at the spacing floor")
assertEq(C.MAX_NEW_POINTS_PER_TICK, math.ceil(C.TELEPORT_DISTANCE / C.MIN_SPACING_FLOOR), "emit cap is derived from teleport distance / spacing floor")
assertAlmost(C.SPACING_THICKNESS_RATIO, 0.10, 1e-9, "stamp spacing is 10% of thickness")
assertEq(C.MIN_SPACING_FLOOR, 1, "spacing floor is 1px")
assertAlmost(Engine.SpacingForThickness(6), 1, 1e-9, "thinnest trail uses the spacing floor")
assertAlmost(Engine.SpacingForThickness(16), 1.6, 1e-9, "default thickness spaces stamps at 1.6px")
assertAlmost(Engine.SpacingForThickness(14), 1.4, 1e-9, "14px thickness spaces stamps at 1.4px")
assertAlmost(Engine.SpacingForThickness(28), 2.8, 1e-9, "thickest trail still overlaps (spacing < diameter)")
assertTrue(Engine.SpacingForThickness(16) < 16 * 0.15, "default spacing is tight enough that circles heavily overlap")
assertTrue(Engine.SpacingForThickness(28) < 28 * 0.15, "thick spacing is tight enough that circles heavily overlap")
assertTrue(Engine.SpacingForThickness(16) * 2 < 16, "default neighbor centers sit well inside one circle diameter")
assertTrue(Engine.SpacingForThickness(28) * 2 < 28, "thick neighbor centers sit well inside one circle diameter")

assertAlmost(Engine.TaperedSize(14, 100, 0, 100), 14, 1e-9, "newest stamp uses full thickness")
assertAlmost(Engine.TaperedSize(14, 100, 0, 0), 14 * 0.40, 1e-9, "oldest stamp uses 40% thickness")
assertAlmost(Engine.TaperedSize(14, 100, 0, 50), 14 * 0.70, 1e-9, "mid-trail stamp is halfway between full and minimum")
assertAlmost(Engine.TaperedSize(14, 10, 10, 10), 14, 1e-9, "a single-point trail stays full thickness")
assertTrue(Engine.TaperedSize(28, 80, 0, 0) >= 28 * 0.35, "oldest thick stamp stays above 35%")
assertTrue(Engine.TaperedSize(28, 80, 0, 0) <= 28 * 0.45, "oldest thick stamp stays at or below 45%")
local prevSize = Engine.TaperedSize(14, 100, 0, 100)
for dist = 90, 0, -10 do
    local size = Engine.TaperedSize(14, 100, 0, dist)
    assertTrue(size <= prevSize + 1e-9, "taper decreases smoothly toward the tail")
    prevSize = size
end
assertAlmost(C.ACTIVE_SAMPLE_INTERVAL, 1 / 60, 1e-9, "active sample cadence is 60 Hz")
assertAlmost(C.FADE_INTERVAL, 1 / 30, 1e-9, "fade cadence is 30 Hz")
assertAlmost(C.IDLE_POLL_INTERVAL, 1 / 60, 1e-9, "idle poll cadence is 60 Hz")

local function newEngine()
    local engine = Engine.New()
    engine:SetScale(1)
    engine:SetConfig(C.DEFAULT_TRAIL_LENGTH, C.DEFAULT_FADE_DURATION, C.DEFAULT_RAINBOW_SPEED, C.DEFAULT_THICKNESS)
    return engine
end

local fresh = Engine.New()
assertEq(fresh.trailLength, 400, "new engine uses the 400px trail-length default")
assertAlmost(fresh.fadeDuration, 0.50, 1e-9, "new engine uses the 0.5s fade default")
assertEq(fresh.thickness, 16, "new engine uses the 16px thickness default")
assertAlmost(fresh.rainbowSpeed, 0.25, 1e-9, "new engine uses the 0.25 rainbow-speed default")
assertAlmost(fresh.minSpacing, 1.6, 1e-9, "new engine spacing follows the 16px default")
fresh:SetConfig(2000, 0.5, 0.25, 14)
assertEq(fresh.trailLength, 1200, "trail length clamps to the 1200px maximum")
fresh:SetConfig(400, 0.5, 0.10, 14)
assertAlmost(fresh.rainbowSpeed, 0.25, 1e-9, "rainbow speed below the slider min clamps to 0.25")

-- HSV / fade / scale helpers
local r1, g1, b1 = Engine.HSVToRGB(0, 1, 1)
assertAlmost(r1, 1, 1e-6, "HSV hue 0 is red")
assertAlmost(g1, 0, 1e-6, "HSV hue 0 green is 0")
assertAlmost(b1, 0, 1e-6, "HSV hue 0 blue is 0")

local r2, g2, b2 = Engine.HSVToRGB(1 / 3, 1, 1)
assertAlmost(r2, 0, 1e-6, "HSV hue 1/3 red is 0")
assertAlmost(g2, 1, 1e-6, "HSV hue 1/3 is green")

local r3, g3, b3 = Engine.HSVToRGB(0, 1, 1)
local r4, g4, b4 = Engine.HSVToRGB(1, 1, 1)
assertAlmost(r3, r4, 1e-6, "HSV wraps 0 and 1 to the same red")
assertAlmost(g3, g4, 1e-6, "HSV wrap green matches")
assertAlmost(b3, b4, 1e-6, "HSV wrap blue matches")

assertEq(Engine.FadeFactor(0, 0.5), 1, "fade at birth is 1")
assertAlmost(Engine.FadeFactor(0.25, 0.5), 0.5, 1e-9, "fade at midpoint is 0.5")
assertEq(Engine.FadeFactor(0.5, 0.5), 0, "fade at duration is 0")
assertEq(Engine.FadeFactor(0.8, 0.5), 0, "expired fade is 0")

local sx, sy = Engine.ScaledCursor(200, 100, 2)
assertEq(sx, 100, "scale helper divides x")
assertEq(sy, 50, "scale helper divides y")
local sx2, sy2 = Engine.ScaledCursor(10, 20, 0)
assertEq(sx2, 10, "invalid scale falls back to 1 for x")
assertEq(sy2, 20, "invalid scale falls back to 1 for y")

assertEq(Engine.ClampNumber(10, 80, 400, 200), 80, "clamp raises below-min")
assertEq(Engine.ClampNumber(900, 80, 400, 200), 400, "clamp lowers above-max")
assertEq(Engine.ClampNumber(nil, 80, 400, 200), 200, "clamp uses fallback for nil")

-- Baseline: first sample does not emit
local e = newEngine()
e:ProcessSample(1.0, 100, 100, false)
assertEq(e.count, 0, "first sample establishes baseline without points")
assertEq(e.activeSegCount, 0, "first sample emits no segments")
assertTrue(e.hasBaseline, "first sample sets the baseline")

-- Zero movement
e:ProcessSample(1.1, 100, 100, false)
assertEq(e.count, 0, "zero movement emits nothing")
assertEq(e.activeSegCount, 0, "zero movement creates no segments")

-- Small rejected movement does not move the acceptance baseline
e = newEngine()
e.minSpacing = 6
e:ProcessSample(1.0, 100, 0, false)
e:ProcessSample(1.1, 102, 0, false)
e:ProcessSample(1.2, 104, 0, false)
e:ProcessSample(1.3, 105, 0, false)
assertEq(e.count, 0, "sub-spacing moves do not emit")
assertEq(e.lastX, 100, "rejected moves keep the last accepted x")
e:ProcessSample(1.4, 107, 0, false)
assertTrue(e.count >= 2, "accumulated small moves emit once 6px is reached")
assertAlmost(e.lastX, 107, 1e-6, "accepted emit reaches 107")
local newestX = select(1, e:GetPoint(e.count))
assertAlmost(newestX, 107, 1e-6, "newest point is the current cursor after accumulation")

-- Thickness-based spacing emit
e = newEngine()
assertAlmost(e.minSpacing, 1.6, 1e-9, "default engine spacing follows 16px thickness")
e:ProcessSample(1.0, 0, 0, false)
e:ProcessSample(1.2, 10, 0, false)
local expectedN = math.min(C.MAX_NEW_POINTS_PER_TICK, math.max(1, math.floor(10 / e.minSpacing)))
assertEq(e.count, expectedN + 1, "10px move stores the start point plus interpolated stamps")
assertEq(e.activeSegCount, expectedN, "10px move creates one segment per new stamp")
local x1 = select(1, e:GetPoint(1))
local x2 = select(1, e:GetPoint(2))
local xLast = select(1, e:GetPoint(e.count))
assertAlmost(x1, 0, 1e-6, "start point is the previous accepted position")
assertAlmost(x2, 10 / expectedN, 1e-6, "first interpolated point uses even catch-up spacing")
assertAlmost(xLast, 10, 1e-6, "final interpolated point is the cursor")

-- Long movement reaches the cursor in one tick without visual gaps
e = newEngine()
e:ProcessSample(2.0, 0, 0, false)
e:ProcessSample(2.1, 150, 0, false)
assertTrue(e.count >= 2, "150px move emits points")
assertTrue(e.activeSegCount <= C.MAX_NEW_POINTS_PER_TICK, "150px move respects the emit cap")
local lastX = select(1, e:GetPoint(e.count))
assertAlmost(lastX, 150, 1e-6, "150px move reaches the current cursor this tick")
assertAlmost(e.lastX, 150, 1e-6, "accepted baseline is the current cursor after a long move")
local prevPx = select(1, e:GetPoint(1))
for chrono = 2, e.count do
    local px = select(1, e:GetPoint(chrono))
    assertTrue((px - prevPx) <= e.minSpacing + 0.05, "interpolated neighbor spacing stays at the thickness spacing")
    assertTrue((px - prevPx) < C.DEFAULT_THICKNESS * 0.5, "fast-move stamps still overlap at default thickness")
    prevPx = px
end

-- Thicker trails use wider spacing but still overlap
e = newEngine()
e:SetConfig(C.DEFAULT_TRAIL_LENGTH, C.DEFAULT_FADE_DURATION, C.DEFAULT_RAINBOW_SPEED, 28)
e:ProcessSample(3.0, 0, 0, false)
e:ProcessSample(3.1, 80, 0, false)
assertAlmost(e.minSpacing, 2.8, 1e-9, "28px thickness uses 2.8px spacing")
prevPx = select(1, e:GetPoint(1))
for chrono = 2, e.count do
    local px = select(1, e:GetPoint(chrono))
    assertTrue((px - prevPx) < 28 * 0.5, "thick-trail stamps overlap")
    prevPx = px
end

-- Just-under-teleport move at the 1px floor still reaches the cursor without gaps
e = newEngine()
e:SetConfig(C.DEFAULT_TRAIL_LENGTH, 1.5, C.DEFAULT_RAINBOW_SPEED, 6)
e:ProcessSample(4.0, 0, 0, false)
e:ProcessSample(4.1, 249, 0, false)
assertAlmost(e.minSpacing, 1, 1e-9, "6px thickness uses the 1px spacing floor")
assertAlmost(select(1, e:GetPoint(e.count)), 249, 1e-6, "249px move at 1px spacing reaches the cursor this tick")
assertTrue(e.activeSegCount <= C.MAX_NEW_POINTS_PER_TICK, "249px move stays within the emit cap")
assertTrue(e.count <= C.MAX_POINTS, "249px move stays within the point pool")
prevPx = select(1, e:GetPoint(1))
for chrono = 2, e.count do
    local px = select(1, e:GetPoint(chrono))
    assertTrue((px - prevPx) <= e.minSpacing + 0.05, "1px-floor interpolation does not leave gaps")
    prevPx = px
end

-- Live trail taper uses path distance from newest to oldest
e = newEngine()
e:SetConfig(C.DEFAULT_TRAIL_LENGTH, 1.5, C.DEFAULT_RAINBOW_SPEED, 14)
e:ProcessSample(6.0, 0, 0, false)
e:ProcessSample(6.1, 80, 0, false)
local newestDist = select(4, e:GetPoint(e.count))
local oldestDist = select(4, e:GetPoint(1))
assertTrue(newestDist > oldestDist, "live trail has a path-distance span")
assertAlmost(Engine.TaperedSize(14, newestDist, oldestDist, newestDist), 14, 1e-9, "live newest stamp is full thickness")
assertAlmost(Engine.TaperedSize(14, newestDist, oldestDist, oldestDist), 14 * 0.40, 1e-9, "live oldest stamp is 40% thickness")
local midDist = (newestDist + oldestDist) / 2
assertAlmost(Engine.TaperedSize(14, newestDist, oldestDist, midDist), 14 * 0.70, 0.05, "live mid-trail stamp is near the halfway taper")
local livePrev = Engine.TaperedSize(14, newestDist, oldestDist, newestDist)
for chrono = e.count, 1, -1 do
    local _, _, _, dist = e:GetPoint(chrono)
    local size = Engine.TaperedSize(14, newestDist, oldestDist, dist)
    assertTrue(size <= livePrev + 1e-9, "live taper shrinks toward the oldest point")
    assertTrue(size >= 14 * 0.40 - 1e-9, "live taper never drops below the 40% floor")
    livePrev = size
end

-- Maximum trail length trims a dense path and stays inside the fixed pool
e = newEngine()
e:SetConfig(1200, 1.5, C.DEFAULT_RAINBOW_SPEED, 6)
e:ProcessSample(7.0, 0, 0, false)
local maxLenT = 7.0
local maxLenCursor = 0
for _ = 1, 8 do
    maxLenCursor = maxLenCursor + 200
    maxLenT = maxLenT + 0.02
    e:ProcessSample(maxLenT, maxLenCursor, 0, false)
end
newestDist = select(4, e:GetPoint(e.count))
oldestDist = select(4, e:GetPoint(1))
assertTrue((newestDist - oldestDist) <= 1200 + 1e-6, "path length is trimmed to the 1200px maximum")
assertTrue(e.count <= C.MAX_POINTS, "max-length dense trail stays within MAX_POINTS")
assertTrue(e.activeSegCount <= C.MAX_SEGMENTS, "max-length dense trail stays within MAX_SEGMENTS")
assertAlmost(select(1, e:GetPoint(e.count)), maxLenCursor, 1e-6, "max-length trail still reaches the current cursor")

-- Ring wrap reports the reused index as released even though it is live again.
-- The host must hide that stamp before PlaceStamp so the newest circle is not left at the tail's faded alpha.
e = newEngine()
e:SetConfig(1200, 1.5, C.DEFAULT_RAINBOW_SPEED, 6)
e:ProcessSample(8.0, 0, 0, false)
local wrapT = 8.0
local wrapCursor = 0
for _ = 1, 6 do
    wrapCursor = wrapCursor + 200
    wrapT = wrapT + 0.02
    e:ProcessSample(wrapT, wrapCursor, 0, false)
end
wrapCursor = wrapCursor + 249
wrapT = wrapT + 0.02
e:ProcessSample(wrapT, wrapCursor, 0, false)
local reusedLive = 0
for i = 1, e.releasedPointCount do
    if e:IsLiveIndex(e.releasedPoints[i]) then
        reusedLive = reusedLive + 1
    end
end
assertTrue(reusedLive > 0, "ring wrap releases slot indices that are immediately reused as live points")
assertTrue(e.count <= C.MAX_POINTS, "wrap still stays within the fixed point pool")
assertAlmost(select(1, e:GetPoint(e.count)), wrapCursor, 1e-6, "wrapped emit still reaches the current cursor")

-- Interpolated timestamps are monotonic
e = newEngine()
e:ProcessSample(5.0, 0, 0, false)
e:ProcessSample(5.5, 48, 0, false)
local prevT = nil
local tCount = 0
for chrono = 2, e.count do
    local _, _, t = e:GetPoint(chrono)
    if prevT then
        assertTrue(t > prevT, "interpolated timestamps increase along a long move")
    end
    prevT = t
    tCount = tCount + 1
end
assertTrue(tCount >= 2, "long move produced multiple timed points")
local _, _, firstT = e:GetPoint(1)
local _, _, lastT = e:GetPoint(e.count)
assertTrue(firstT < lastT, "oldest interpolated time is before the newest")
assertAlmost(lastT, 5.5, 1e-9, "newest interpolated timestamp is the current sample time")

-- Teleport reseeds without emitting
e = newEngine()
e:ProcessSample(1.0, 0, 0, false)
e:ProcessSample(1.1, 20, 0, false)
local beforeCount = e.count
e:ProcessSample(1.2, 20 + C.TELEPORT_DISTANCE + 10, 0, false)
assertEq(e.count, beforeCount, "teleport does not emit connecting points")
assertEq(e.lastAcceptedIdx, 0, "teleport clears the last accepted index")
e:ProcessSample(1.3, 20 + C.TELEPORT_DISTANCE + 10, 0, false)
assertEq(e.count, beforeCount, "sample immediately after teleport is baseline-only")

-- Mouselook reseeds
e = newEngine()
e:ProcessSample(1.0, 0, 0, false)
e:ProcessSample(1.1, 18, 0, false)
local lookCount = e.count
e:ProcessSample(1.2, 40, 0, true)
assertEq(e.count, lookCount, "mouselook does not emit")
assertTrue(e.wasMouselook, "mouselook flags the engine")
e:ProcessSample(1.3, 80, 0, false)
assertEq(e.count, lookCount, "first sample after mouselook establishes baseline only")
assertTrue(not e.wasMouselook, "leaving mouselook clears the flag")
e:ProcessSample(1.4, 92, 0, false)
assertTrue(e.count > lookCount, "later movement after mouselook emits from the new baseline")
local newestAfterLook = select(1, e:GetPoint(e.count))
assertAlmost(newestAfterLook, 92, 1e-6, "post-mouselook emit reaches the new cursor")

-- Fade expiration drops oldest points and segments
e = newEngine()
e:SetConfig(400, 0.50, 1.0)
e:ProcessSample(1.0, 0, 0, false)
e:ProcessSample(1.1, 24, 0, false)
assertTrue(e.activeSegCount > 0, "pre-fade trail has segments")
e:ProcessFade(1.1 + 0.50)
assertEq(e.count, 0, "fully expired points are removed")
assertEq(e.activeSegCount, 0, "fully expired segments are released")
assertTrue(e.releasedPointCount > 0, "fade records released stamp indices")
assertEq(e.lastAcceptedIdx, 0, "empty ring clears lastAcceptedIdx")

-- A new stroke after a full fade must not inherit the stale start timestamp
e:ProcessSample(3.0, 24, 0, false)
e:ProcessSample(3.1, 40, 0, false)
assertTrue(e.count >= 2, "movement after a full fade emits a new stroke")
assertTrue(e.activeSegCount >= 1, "movement after a full fade creates a visible segment")
local _, _, restartT = e:GetPoint(1)
assertTrue(restartT >= 3.0 - 1e-9, "new stroke after fade uses the current time, not the stale lastT")
local newestAfterFade = select(1, e:GetPoint(e.count))
assertAlmost(newestAfterFade, 40, 1e-6, "new stroke after fade reaches the current cursor")

-- Trail-length trimming
e = newEngine()
e:SetConfig(80, 1.5, 1.0)
e:ProcessSample(1.0, 0, 0, false)
local t = 1.1
local cursor = 0
for _ = 1, 8 do
    cursor = cursor + 24
    t = t + 0.05
    e:ProcessSample(t, cursor, 0, false)
end
local newest = select(4, e:GetPoint(e.count))
local oldest = select(4, e:GetPoint(1))
assertTrue((newest - oldest) <= 80 + 1e-6, "path length is trimmed to trailLength")
assertTrue(e.count <= C.MAX_POINTS, "trim keeps count within MAX_POINTS")

local function assertRingSynchronized(engine, label)
    assertTrue(engine.count <= C.MAX_POINTS, label .. ": count stays within MAX_POINTS")
    assertTrue(engine.activeSegCount <= C.MAX_SEGMENTS, label .. ": segments stay within MAX_SEGMENTS")
    if engine.count < 2 then
        assertEq(engine.activeSegCount, 0, label .. ": fewer than two points means no segments")
        return
    end
    assertEq(engine.activeSegCount, engine.count - 1, label .. ": exactly one segment per adjacent pair")

    local live = {}
    local prevDist = -1
    local prevX, prevY, prevT
    for chrono = 1, engine.count do
        local x, y, pt, dist, idx = engine:GetPoint(chrono)
        assertTrue(idx ~= nil, label .. ": chronological point has a ring index")
        live[idx] = chrono
        assertTrue(dist >= prevDist, label .. ": chronological distances are non-decreasing")
        if prevT then
            assertTrue(pt >= prevT, label .. ": chronological timestamps are non-decreasing")
        end
        prevDist = dist
        prevX, prevY, prevT = x, y, pt
    end
    assertTrue(prevX ~= nil and prevY ~= nil, label .. ": live points exist")

    local pairSeen = {}
    local staleInactive = 0
    for i = 1, C.MAX_SEGMENTS do
        if engine.segActive[i] then
            local i0 = engine.segI0[i]
            local i1 = engine.segI1[i]
            assertTrue(live[i0] ~= nil, label .. ": segment i0 is a live point")
            assertTrue(live[i1] ~= nil, label .. ": segment i1 is a live point")
            assertEq(live[i1], live[i0] + 1, label .. ": segment connects chronological neighbors")
            assertTrue(not pairSeen[i0], label .. ": only one segment uses this older neighbor")
            pairSeen[i0] = true
            local dx = engine.px[i1] - engine.px[i0]
            local dy = engine.py[i1] - engine.py[i0]
            assertTrue((dx * dx + dy * dy) > 0, label .. ": active segment has non-zero length")
            assertTrue(engine.segBorn[i] ~= 0, label .. ": active segment has a birth time")
        elseif engine.segI0[i] ~= 0 or engine.segI1[i] ~= 0 or engine.segBorn[i] ~= 0
            or engine.segDist[i] ~= 0 or engine.segR[i] ~= 0 or engine.segG[i] ~= 0 or engine.segB[i] ~= 0 then
            staleInactive = staleInactive + 1
        end
    end
    assertEq(staleInactive, 0, label .. ": inactive segments keep no stale fields")
end

-- Ring wrap + neighbor synchronization
e = newEngine()
e:SetConfig(400, 1.5, 1.0)
e:ProcessSample(1.0, 0, 0, false)
t = 1.05
cursor = 0
for _ = 1, 40 do
    cursor = cursor + 18
    t = t + 0.02
    e:ProcessSample(t, cursor, 0, false)
end
local oldestX = select(1, e:GetPoint(1))
assertTrue(type(oldestX) == "number" and oldestX > 0, "wrap/trim discarded the original origin point")
assertRingSynchronized(e, "after wraparound")

-- Fade expiration after wrap still keeps neighbors synchronized
local fadeNow = t + 0.25
e:ProcessFade(fadeNow)
assertRingSynchronized(e, "after fade following wrap")

-- Further reuse after wrap does not inherit old visual/state data
cursor = cursor + 24
t = t + 0.02
e:ProcessSample(t, cursor, 0, false)
assertRingSynchronized(e, "after reuse following wrap")
local newestAfterReuse = select(1, e:GetPoint(e.count))
assertAlmost(newestAfterReuse, cursor, 1e-6, "reused ring writes the newest cursor, not an old coordinate")

-- Reused slots do not keep old timestamps after reset+replay
e:Reset()
e:SetConfig(C.DEFAULT_TRAIL_LENGTH, C.DEFAULT_FADE_DURATION, C.DEFAULT_RAINBOW_SPEED)
e:ProcessSample(20.0, 0, 0, false)
e:ProcessSample(20.1, 12, 0, false)
local _, _, reusedT = e:GetPoint(e.count)
assertAlmost(reusedT, 20.1, 1e-9, "reused engine writes the new sample time")
assertRingSynchronized(e, "after reset and replay")

-- ProcessFade on empty engine is a no-op
e:Reset()
e:ProcessFade(1.0)
assertEq(e.count, 0, "fade on empty engine leaves count at 0")
assertEq(e.activeSegCount, 0, "fade on empty engine leaves no segments")
assertEq(e.releasedCount, 0, "fade on empty engine releases nothing")

-- Rainbow continuity: neighboring segment hues stay close on a short step
e = newEngine()
e:ProcessSample(1.0, 0, 0, false)
e:ProcessSample(1.1, 6, 0, false)
e:ProcessSample(1.2, 12, 0, false)
local firstHueSeg, secondHueSeg
for i = 1, C.MAX_SEGMENTS do
    if e.segActive[i] then
        if not firstHueSeg then
            firstHueSeg = i
        else
            secondHueSeg = i
        end
    end
end
assertTrue(firstHueSeg and secondHueSeg, "two neighboring segments exist for hue compare")
local dr = e.segR[secondHueSeg] - e.segR[firstHueSeg]
local dg = e.segG[secondHueSeg] - e.segG[firstHueSeg]
local db = e.segB[secondHueSeg] - e.segB[firstHueSeg]
assertTrue((dr * dr + dg * dg + db * db) < 0.25, "neighboring rainbow colors are continuous")

-- Live ring indices used by circular stamps
e = newEngine()
e:ProcessSample(1.0, 0, 0, false)
e:ProcessSample(1.1, 18, 0, false)
assertTrue(e:IsLiveIndex(e:ChronoIndex(1)), "oldest point is live")
assertTrue(e:IsLiveIndex(e:ChronoIndex(e.count)), "newest point is live")
assertTrue(not e:IsLiveIndex(0), "index 0 is never live")
assertTrue(not e:IsLiveIndex(C.MAX_POINTS + 1), "out-of-range index is not live")
e:Reset()
assertTrue(not e:IsLiveIndex(1), "reset engine has no live points")
assertEq(C.CIRCLE_TEXTURE, "Interface\\CharacterFrame\\TempPortraitAlphaMask", "trail stamps use the circular portrait mask")

local tracerChunk = assert(loadfile(repoPath("SpectrumFederation/modules/MouseTracer/MouseTracer.lua")))
tracerChunk("SpectrumFederation", SF)
local Tracer = SF.MouseTracer

local copyOptions = {
    { value = "Other-Realm", label = "Other-Realm" },
    { value = "Alt-Realm", label = "Alt-Realm" },
}
assertTrue(not Tracer.IsCopySelectionEnabled(nil, copyOptions), "Copy stays disabled with no selection")
assertTrue(not Tracer.IsCopySelectionEnabled("", copyOptions), "Copy stays disabled for an empty selection")
assertTrue(not Tracer.IsCopySelectionEnabled("Self-Realm", copyOptions), "Copy stays disabled for the current/missing character")
assertTrue(not Tracer.IsCopySelectionEnabled("Other-Realm", {}), "Copy stays disabled when no sources exist")
assertTrue(not Tracer.IsCopySelectionEnabled("Other-Realm", nil), "Copy stays disabled when options are missing")
assertTrue(Tracer.IsCopySelectionEnabled("Other-Realm", copyOptions), "Copy enables for a valid other character")
assertTrue(Tracer.IsCopySelectionEnabled("Alt-Realm", copyOptions), "Copy enables for each valid listed character")

Tracer:SetCopySource(nil)
assertTrue(not Tracer:CanCopy(), "CanCopy is false before a source is chosen")
-- CanCopy uses live GetCopyOptions (empty without a store), so exercise SetCopySource sanitizing only.
Tracer:SetCopySource("Other-Realm")
assertEq(Tracer:GetCopySource(), "Other-Realm", "SetCopySource keeps a non-empty character id")
Tracer:SetCopySource("")
assertEq(Tracer:GetCopySource(), nil, "SetCopySource clears an empty selection")

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then
    os.exit(1)
end
