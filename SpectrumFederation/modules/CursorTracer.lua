local addonName, SF = ...

SF.CursorTracer = SF.CursorTracer or {}
local CursorTracer = SF.CursorTracer

CursorTracer.MIN_TRAIL_LENGTH = 0.05
CursorTracer.MAX_TRAIL_LENGTH = 2.0
CursorTracer.DEFAULT_TRAIL_LENGTH = 0.18
CursorTracer.UPDATE_INTERVAL = 0.015
CursorTracer.DORMANT_INTERVAL = 0.05
CursorTracer.HITCH_THRESHOLD = 0.2
CursorTracer.MAX_DOTS = 128
CursorTracer.DOT_SPACING = 7
CursorTracer.DOT_TEXTURE = "Interface\\Cooldown\\ping4"
CursorTracer.DOT_BLEND_MODE = "ADD"
CursorTracer.DOT_BASE_SIZE = 18
CursorTracer.DOT_MIN_SCALE = 0.35
CursorTracer.DOT_ALPHA = 0.34
CursorTracer.DISTANCE_FADE = 0.82
CursorTracer.COLOR_SATURATION = 0.58
CursorTracer.COLOR_VALUE = 0.92
CursorTracer.RAINBOW_SPEED = 0.22
CursorTracer.PHASE_COUNT = 18
CursorTracer.MIN_MOVE_THRESHOLD_SQ = 1
CursorTracer.OFFSET_X = 0
CursorTracer.OFFSET_Y = 0

local function ClampTrailLength(value)
	value = tonumber(value) or CursorTracer.DEFAULT_TRAIL_LENGTH
	if value < CursorTracer.MIN_TRAIL_LENGTH then
		return CursorTracer.MIN_TRAIL_LENGTH
	end
	if value > CursorTracer.MAX_TRAIL_LENGTH then
		return CursorTracer.MAX_TRAIL_LENGTH
	end
	return value
end

local function HSVToRGB(h, s, v)
	h = h - math.floor(h)
	s = s or 1
	v = v or 1

	local i = math.floor(h * 6)
	local f = (h * 6) - i
	local p = v * (1 - s)
	local q = v * (1 - (f * s))
	local t = v * (1 - ((1 - f) * s))
	local mod = i % 6

	if mod == 0 then
		return v, t, p
	elseif mod == 1 then
		return q, v, p
	elseif mod == 2 then
		return p, v, t
	elseif mod == 3 then
		return p, q, v
	elseif mod == 4 then
		return t, p, v
	end

	return v, p, q
end

function CursorTracer:Init()
	if self.initialized then return end
	self.initialized = true

	self.trailLength = self.DEFAULT_TRAIL_LENGTH
	self.elapsed = 0
	self.head = 0
	self.count = 0
	self.sequence = 0
	self.remainingToNextDot = self.DOT_SPACING
	self.lastCursorX = nil
	self.lastCursorY = nil
	self.dormant = true

	self:EnsureFrame()
	self:Start()
	self:HideAll()
end

function CursorTracer:EnsureFrame()
	if self.frame then return end

	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetAllPoints(UIParent)
	frame:SetFrameStrata("TOOLTIP")
	frame:EnableMouse(false)

	self.frame = frame
	self.textures = {}
	self.dots = {}
	self.onUpdate = function(_, elapsed)
		self:OnUpdate(elapsed)
	end

	for index = 1, self.MAX_DOTS do
		local texture = frame:CreateTexture(nil, "OVERLAY")
		texture:SetTexture(self.DOT_TEXTURE)
		texture:SetBlendMode(self.DOT_BLEND_MODE)
		texture:Hide()
		self.textures[index] = texture
		self.dots[index] = {
			x = 0,
			y = 0,
			time = 0,
			sequence = 0,
		}
	end
end

function CursorTracer:Start()
	if not self.frame then return end
	self.frame:SetScript("OnUpdate", self.onUpdate)
end

function CursorTracer:SetTrailLength(seconds)
	self:Init()
	self.trailLength = ClampTrailLength(seconds)
end

function CursorTracer:GetTrailLength()
	self:Init()
	return self.trailLength
end

function CursorTracer:HideAll()
	for _, texture in ipairs(self.textures or {}) do
		texture:Hide()
	end
end

function CursorTracer:ResetTrail()
	self.head = 0
	self.count = 0
	self.sequence = 0
	self.remainingToNextDot = self.DOT_SPACING
	self:HideAll()
end

function CursorTracer:RefreshTrail(now)
	self:Init()

	now = now or (GetTime and GetTime()) or 0

	local visible = 0
	local timePhase = now * self.RAINBOW_SPEED

	for offset = 0, (self.count or 0) - 1 do
		local slot = ((self.head - offset - 1) % self.MAX_DOTS) + 1
		local dot = self.dots[slot]
		local age = now - (dot.time or 0)

		if age <= self.trailLength then
			local texture = self.textures[visible + 1]
			local ageProgress = 1 - (age / self.trailLength)
			local distanceProgress = 1 - (offset / math.max(self.count - 1, 1))
			local visibility = ageProgress * (self.DISTANCE_FADE + ((1 - self.DISTANCE_FADE) * distanceProgress))
			local scale = self.DOT_MIN_SCALE + ((1 - self.DOT_MIN_SCALE) * visibility)
			local hue = timePhase + ((dot.sequence or 0) / self.PHASE_COUNT)
			local r, g, b = HSVToRGB(hue, self.COLOR_SATURATION, self.COLOR_VALUE)

			texture:ClearAllPoints()
			texture:SetPoint("CENTER", self.frame, "BOTTOMLEFT", dot.x + self.OFFSET_X, dot.y + self.OFFSET_Y)
			texture:SetSize(self.DOT_BASE_SIZE * scale, self.DOT_BASE_SIZE * scale)
			texture:SetVertexColor(r, g, b)
			texture:SetAlpha(self.DOT_ALPHA * visibility)
			texture:Show()
			visible = visible + 1
		end
	end

	for index = visible + 1, self.MAX_DOTS do
		self.textures[index]:Hide()
	end

	self.dormant = visible == 0
end

function CursorTracer:PushDot(x, y, now)
	self.head = (self.head % self.MAX_DOTS) + 1
	self.count = math.min(self.count + 1, self.MAX_DOTS)
	self.sequence = self.sequence + 1

	local dot = self.dots[self.head]
	dot.x = x
	dot.y = y
	dot.time = now
	dot.sequence = self.sequence
end

function CursorTracer:EmitInterpolatedDots(startX, startY, endX, endY, now)
	local dx = endX - startX
	local dy = endY - startY
	local distanceSq = (dx * dx) + (dy * dy)

	if distanceSq < self.MIN_MOVE_THRESHOLD_SQ then
		return false
	end

	local distance = math.sqrt(distanceSq)
	local consumed = 0
	local emitted = false

	while (distance - consumed) >= self.remainingToNextDot do
		consumed = consumed + self.remainingToNextDot
		local t = consumed / distance
		self:PushDot(startX + (dx * t), startY + (dy * t), now)
		self.remainingToNextDot = self.DOT_SPACING
		emitted = true
	end

	self.remainingToNextDot = self.remainingToNextDot - (distance - consumed)
	if self.remainingToNextDot <= 0 then
		self.remainingToNextDot = self.DOT_SPACING
	end

	return emitted
end

function CursorTracer:OnUpdate(elapsed)
	self:Init()

	elapsed = elapsed or 0
	if elapsed >= self.HITCH_THRESHOLD then
		self.elapsed = 0
		self:ResetTrail()
		self.lastCursorX = nil
		self.lastCursorY = nil
		self.dormant = true
		return
	end

	self.elapsed = self.elapsed + elapsed
	local targetInterval = self.dormant and self.DORMANT_INTERVAL or self.UPDATE_INTERVAL
	if self.elapsed < targetInterval then
		return
	end

	local delta = self.elapsed
	self.elapsed = 0

	local scale = UIParent:GetEffectiveScale()
	if not scale or scale == 0 then return end

	local rawX, rawY = GetCursorPosition()
	local x = rawX / scale
	local y = rawY / scale
	local now = (GetTime and GetTime()) or 0

	if not self.lastCursorX or not self.lastCursorY then
		self.lastCursorX = x
		self.lastCursorY = y
		self:RefreshTrail(now)
		return
	end

	local moved = self:EmitInterpolatedDots(self.lastCursorX, self.lastCursorY, x, y, now)
	self.lastCursorX = x
	self.lastCursorY = y

	if moved then
		self.dormant = false
	elseif delta >= self.trailLength and self.count == 0 then
		self.dormant = true
	end

	self:RefreshTrail(now)
end
