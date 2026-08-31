local _, SF = ...

SF.MouseTracer = SF.MouseTracer or {}
local C = SF.MouseTracer.Constants
local Engine = {}
SF.MouseTracer.TrailEngine = Engine

local function Clamp(value, minValue, maxValue, fallback)
	value = tonumber(value)
	if not value then
		return fallback
	end
	if value < minValue then
		return minValue
	end
	if value > maxValue then
		return maxValue
	end
	return value
end

function Engine.ClampNumber(value, minValue, maxValue, fallback)
	return Clamp(value, minValue, maxValue, fallback)
end

function Engine.HSVToRGB(h, s, v)
	if h ~= h then
		return v, v, v
	end
	h = h - math.floor(h)
	if h < 0 then
		h = h + 1
	end
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p = v * (1 - s)
	local q = v * (1 - f * s)
	local t = v * (1 - (1 - f) * s)
	i = i - math.floor(i / 6) * 6
	if i == 0 then
		return v, t, p
	elseif i == 1 then
		return q, v, p
	elseif i == 2 then
		return p, v, t
	elseif i == 3 then
		return p, q, v
	elseif i == 4 then
		return t, p, v
	end
	return v, p, q
end

function Engine.FadeFactor(age, fadeDuration)
	fadeDuration = tonumber(fadeDuration) or 0
	age = tonumber(age) or 0
	if fadeDuration <= 0 then
		return 0
	end
	if age <= 0 then
		return 1
	end
	if age >= fadeDuration then
		return 0
	end
	return 1 - (age / fadeDuration)
end

function Engine.ScaledCursor(rawX, rawY, scale)
	if not scale or scale <= 0 then
		scale = 1
	end
	return rawX / scale, rawY / scale
end

local function AcquireSeg(self)
	if self.freeCount < 1 then
		return nil
	end
	local id = self.free[self.freeCount]
	self.freeCount = self.freeCount - 1
	self.segActive[id] = true
	self.activeSegCount = self.activeSegCount + 1
	return id
end

local function ReleaseSeg(self, id)
	if not self.segActive[id] then
		return
	end
	self.segActive[id] = false
	self.segI0[id] = 0
	self.segI1[id] = 0
	self.segBorn[id] = 0
	self.segDist[id] = 0
	self.segR[id] = 0
	self.segG[id] = 0
	self.segB[id] = 0
	self.freeCount = self.freeCount + 1
	self.free[self.freeCount] = id
	self.activeSegCount = self.activeSegCount - 1
	self.releasedCount = self.releasedCount + 1
	self.releasedSegs[self.releasedCount] = id
end

local function ReleaseSegmentsForPoint(self, pointIdx)
	local maxS = C.MAX_SEGMENTS
	for i = 1, maxS do
		if self.segActive[i] and (self.segI0[i] == pointIdx or self.segI1[i] == pointIdx) then
			ReleaseSeg(self, i)
		end
	end
end

local function NewestIdx(self)
	if self.count < 1 then
		return nil
	end
	return ((self.head + self.count - 2) % C.MAX_POINTS) + 1
end

local function NoteReleasedPoint(self, idx)
	self.releasedPointCount = self.releasedPointCount + 1
	self.releasedPoints[self.releasedPointCount] = idx
end

local function DropOldest(self)
	if self.count < 1 then
		return
	end
	ReleaseSegmentsForPoint(self, self.head)
	NoteReleasedPoint(self, self.head)
	self.px[self.head] = 0
	self.py[self.head] = 0
	self.pt[self.head] = 0
	self.pdist[self.head] = 0
	self.head = (self.head % C.MAX_POINTS) + 1
	self.count = self.count - 1
	if self.count == 0 then
		self.lastAcceptedIdx = 0
	end
end

local function PushPoint(self, x, y, t, dist)
	local idx
	if self.count < C.MAX_POINTS then
		idx = ((self.head + self.count - 1) % C.MAX_POINTS) + 1
		self.count = self.count + 1
	else
		ReleaseSegmentsForPoint(self, self.head)
		NoteReleasedPoint(self, self.head)
		idx = self.head
		self.px[idx] = 0
		self.py[idx] = 0
		self.pt[idx] = 0
		self.pdist[idx] = 0
		self.head = (self.head % C.MAX_POINTS) + 1
	end
	self.px[idx] = x
	self.py[idx] = y
	self.pt[idx] = t
	self.pdist[idx] = dist
	return idx
end

local function Trim(self, now)
	while self.count > 0 do
		if (now - self.pt[self.head]) < self.fadeDuration then
			break
		end
		DropOldest(self)
	end
	while self.count > 1 do
		local newest = NewestIdx(self)
		if (self.pdist[newest] - self.pdist[self.head]) <= self.trailLength then
			break
		end
		DropOldest(self)
	end
end

local function ActivateSegment(self, i0, i1, dist)
	local id = AcquireSeg(self)
	if not id then
		return nil
	end
	self.segI0[id] = i0
	self.segI1[id] = i1
	self.segBorn[id] = self.pt[i0]
	self.segDist[id] = dist
	local hue = dist * C.HUE_PER_PIXEL * self.rainbowSpeed
	local r, g, b = Engine.HSVToRGB(hue, 1, 1)
	self.segR[id] = r
	self.segG[id] = g
	self.segB[id] = b
	self.newSegCount = self.newSegCount + 1
	self.newSegs[self.newSegCount] = id
	return id
end

local EngineMeta = { __index = Engine }

function Engine.New()
	local self = setmetatable({}, EngineMeta)
	Engine.InitStorage(self)
	Engine.Reset(self)
	return self
end

function Engine.InitStorage(self)
	local maxP = C.MAX_POINTS
	local maxS = C.MAX_SEGMENTS
	self.px = {}
	self.py = {}
	self.pt = {}
	self.pdist = {}
	self.segI0 = {}
	self.segI1 = {}
	self.segBorn = {}
	self.segDist = {}
	self.segR = {}
	self.segG = {}
	self.segB = {}
	self.segActive = {}
	self.free = {}
	self.newSegs = {}
	self.releasedSegs = {}
	self.releasedPoints = {}
	for i = 1, maxP do
		self.px[i] = 0
		self.py[i] = 0
		self.pt[i] = 0
		self.pdist[i] = 0
		self.releasedPoints[i] = 0
	end
	for i = 1, maxS do
		self.segI0[i] = 0
		self.segI1[i] = 0
		self.segBorn[i] = 0
		self.segDist[i] = 0
		self.segR[i] = 0
		self.segG[i] = 0
		self.segB[i] = 0
		self.segActive[i] = false
		self.free[i] = i
		self.newSegs[i] = 0
		self.releasedSegs[i] = 0
	end
end

function Engine.Reset(self)
	local maxP = C.MAX_POINTS
	local maxS = C.MAX_SEGMENTS
	for i = 1, maxP do
		self.px[i] = 0
		self.py[i] = 0
		self.pt[i] = 0
		self.pdist[i] = 0
		self.releasedPoints[i] = 0
	end
	for i = 1, maxS do
		self.segActive[i] = false
		self.segI0[i] = 0
		self.segI1[i] = 0
		self.segBorn[i] = 0
		self.segDist[i] = 0
		self.segR[i] = 0
		self.segG[i] = 0
		self.segB[i] = 0
		self.free[i] = i
		self.newSegs[i] = 0
		self.releasedSegs[i] = 0
	end
	self.freeCount = maxS
	self.newSegCount = 0
	self.releasedCount = 0
	self.releasedPointCount = 0
	self.activeSegCount = 0
	self.head = 1
	self.count = 0
	self.lastAcceptedIdx = 0
	self.lastX = 0
	self.lastY = 0
	self.lastT = 0
	self.lastDist = 0
	self.hasBaseline = false
	self.wasMouselook = false
	self.trailLength = C.DEFAULT_TRAIL_LENGTH
	self.fadeDuration = C.DEFAULT_FADE_DURATION
	self.rainbowSpeed = C.DEFAULT_RAINBOW_SPEED
	self.thickness = C.DEFAULT_THICKNESS
	self.minSpacing = Engine.SpacingForThickness(C.DEFAULT_THICKNESS)
	self.scale = 1
end

function Engine.SpacingForThickness(thickness)
	thickness = Clamp(thickness, C.MIN_THICKNESS, C.MAX_THICKNESS, C.DEFAULT_THICKNESS)
	local spacing = thickness * C.SPACING_THICKNESS_RATIO
	if spacing < C.MIN_SPACING_FLOOR then
		return C.MIN_SPACING_FLOOR
	end
	return spacing
end

-- Newest point uses full thickness; oldest uses TAPER_MIN_RATIO of thickness.
function Engine.TaperedSize(thickness, newestDist, oldestDist, pointDist)
	thickness = Clamp(thickness, C.MIN_THICKNESS, C.MAX_THICKNESS, C.DEFAULT_THICKNESS)
	local minRatio = C.TAPER_MIN_RATIO
	if not newestDist or not oldestDist or newestDist <= oldestDist then
		return thickness
	end
	pointDist = tonumber(pointDist) or newestDist
	local t = (newestDist - pointDist) / (newestDist - oldestDist)
	if t < 0 then
		t = 0
	elseif t > 1 then
		t = 1
	end
	return thickness * (1 - t * (1 - minRatio))
end

function Engine.SetConfig(self, trailLength, fadeDuration, rainbowSpeed, thickness)
	self.trailLength = Clamp(trailLength, C.MIN_TRAIL_LENGTH, C.MAX_TRAIL_LENGTH, C.DEFAULT_TRAIL_LENGTH)
	self.fadeDuration = Clamp(fadeDuration, C.MIN_FADE_DURATION, C.MAX_FADE_DURATION, C.DEFAULT_FADE_DURATION)
	self.rainbowSpeed = Clamp(rainbowSpeed, C.MIN_RAINBOW_SPEED, C.MAX_RAINBOW_SPEED, C.DEFAULT_RAINBOW_SPEED)
	if thickness == nil then
		thickness = self.thickness or C.DEFAULT_THICKNESS
	end
	self.thickness = Clamp(thickness, C.MIN_THICKNESS, C.MAX_THICKNESS, C.DEFAULT_THICKNESS)
	self.minSpacing = Engine.SpacingForThickness(self.thickness)
end

function Engine.SetScale(self, scale)
	if not scale or scale <= 0 then
		scale = 1
	end
	self.scale = scale
end

function Engine.InvalidateBaseline(self)
	self.hasBaseline = false
	self.wasMouselook = false
	self.lastAcceptedIdx = 0
end

function Engine.ChronoIndex(self, chrono)
	if chrono < 1 or chrono > self.count then
		return nil
	end
	return ((self.head + chrono - 2) % C.MAX_POINTS) + 1
end

function Engine.IsLiveIndex(self, idx)
	if self.count < 1 or not idx or idx < 1 or idx > C.MAX_POINTS then
		return false
	end
	local offset = idx - self.head
	if offset < 0 then
		offset = offset + C.MAX_POINTS
	end
	return offset < self.count
end

function Engine.GetPoint(self, chrono)
	local idx = Engine.ChronoIndex(self, chrono)
	if not idx then
		return nil
	end
	return self.px[idx], self.py[idx], self.pt[idx], self.pdist[idx], idx
end

function Engine.RecolorActive(self)
	local maxS = C.MAX_SEGMENTS
	for i = 1, maxS do
		if self.segActive[i] then
			local hue = self.segDist[i] * C.HUE_PER_PIXEL * self.rainbowSpeed
			local r, g, b = Engine.HSVToRGB(hue, 1, 1)
			self.segR[i] = r
			self.segG[i] = g
			self.segB[i] = b
		end
	end
end

function Engine.ProcessSample(self, now, rawX, rawY, isMouselook)
	self.newSegCount = 0
	self.releasedCount = 0
	self.releasedPointCount = 0

	if isMouselook then
		self.wasMouselook = true
		return
	end

	if self.wasMouselook then
		self.wasMouselook = false
		self.hasBaseline = false
		self.lastAcceptedIdx = 0
	end

	local x, y = Engine.ScaledCursor(rawX, rawY, self.scale)

	if not self.hasBaseline then
		self.lastX = x
		self.lastY = y
		self.lastT = now
		self.hasBaseline = true
		return
	end

	local dx = x - self.lastX
	local dy = y - self.lastY
	local dist = math.sqrt(dx * dx + dy * dy)

	if dist < self.minSpacing then
		return
	end

	if dist > C.TELEPORT_DISTANCE then
		self.lastX = x
		self.lastY = y
		self.lastT = now
		self.lastAcceptedIdx = 0
		self.hasBaseline = true
		return
	end

	local n = math.min(C.MAX_NEW_POINTS_PER_TICK, math.max(1, math.floor(dist / self.minSpacing)))
	local spacing = dist / n
	local prevT = self.lastT
	local dt = now - prevT
	local startX = self.lastX
	local startY = self.lastY
	local startDist = self.lastDist
	local prevIdx = self.lastAcceptedIdx
	if prevIdx == 0 or self.count == 0 then
		prevIdx = PushPoint(self, startX, startY, prevT, startDist)
	end

	for i = 1, n do
		local frac = i / n
		local px = startX + dx * frac
		local py = startY + dy * frac
		local pt
		if dt > 0 then
			pt = prevT + dt * frac
		else
			pt = now
		end
		local pd = startDist + spacing * i
		local newIdx = PushPoint(self, px, py, pt, pd)
		ActivateSegment(self, prevIdx, newIdx, pd)
		prevIdx = newIdx
	end

	self.lastX = x
	self.lastY = y
	self.lastT = now
	self.lastDist = startDist + dist
	self.lastAcceptedIdx = prevIdx

	Trim(self, now)
end

function Engine.ProcessFade(self, now)
	self.newSegCount = 0
	self.releasedCount = 0
	self.releasedPointCount = 0
	if self.count < 1 and self.activeSegCount < 1 then
		return
	end
	Trim(self, now)
end

function Engine.HasActiveTrail(self)
	return self.activeSegCount > 0
end
