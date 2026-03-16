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
CursorTracer.DOT_SPACING = 4
CursorTracer.DOT_ATLAS = "VignetteKill"
CursorTracer.DOT_TEXTURE = "Interface\\Cooldown\\star4"
CursorTracer.HEAD_ATLAS = "VignetteKill"
CursorTracer.HEAD_TEXTURE = "Interface\\Cooldown\\star4"
CursorTracer.DOT_BLEND_MODE = "ADD"
CursorTracer.DOT_BASE_SIZE = 20
CursorTracer.HEAD_SIZE = 24
CursorTracer.DOT_MIN_SCALE = 0.68
CursorTracer.DOT_ALPHA = 0.56
CursorTracer.HEAD_ALPHA = 0.9
CursorTracer.DISTANCE_FADE = 0.92
CursorTracer.COLOR_SATURATION = 0.92
CursorTracer.COLOR_VALUE = 1.0
CursorTracer.RAINBOW_CYCLE_DISTANCE = 72
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

local function AtlasExists(atlas)
	return atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
end

local function ApplyTextureVisual(texture, atlas, fallbackTexture)
	if AtlasExists(atlas) and texture.SetAtlas then
		texture:SetAtlas(atlas, false)
	else
		texture:SetTexture(fallbackTexture)
	end
end

function CursorTracer:Init()
	if self.initialized then return end
	self.initialized = true

	self.trailLength = self.DEFAULT_TRAIL_LENGTH
	self.elapsed = 0
	self.head = 0
	self.count = 0
	self.remainingToNextDot = self.DOT_SPACING
	self.cursorDistance = 0
	self.lastCursorX = nil
	self.lastCursorY = nil
	self.lastMotionTime = 0
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
		ApplyTextureVisual(texture, self.DOT_ATLAS, self.DOT_TEXTURE)
		texture:SetBlendMode(self.DOT_BLEND_MODE)
		texture:Hide()
		self.textures[index] = texture
		self.dots[index] = {
			x = 0,
			y = 0,
			time = 0,
			distance = 0,
		}
	end

	self.headTexture = frame:CreateTexture(nil, "OVERLAY")
	ApplyTextureVisual(self.headTexture, self.HEAD_ATLAS, self.HEAD_TEXTURE)
	self.headTexture:SetBlendMode(self.DOT_BLEND_MODE)
	self.headTexture:Hide()
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
	if self.headTexture then
		self.headTexture:Hide()
	end
end

function CursorTracer:ResetTrail()
	self.head = 0
	self.count = 0
	self.remainingToNextDot = self.DOT_SPACING
	self.cursorDistance = 0
	self.lastMotionTime = 0
	self:HideAll()
end

function CursorTracer:PushDot(x, y, now, distance)
	self.head = (self.head % self.MAX_DOTS) + 1
	self.count = math.min(self.count + 1, self.MAX_DOTS)

	local dot = self.dots[self.head]
	dot.x = x
	dot.y = y
	dot.time = now
	dot.distance = distance or 0
end

function CursorTracer:RefreshTrail(now)
	self:Init()
	now = now or (GetTime and GetTime()) or 0

	local visible = 0
	local headVisible = false

	for offset = 0, (self.count or 0) - 1 do
		local slot = ((self.head - offset - 1) % self.MAX_DOTS) + 1
		local dot = self.dots[slot]
		local age = now - (dot.time or 0)

		if age > self.trailLength then
			break
		end

		local texture = self.textures[visible + 1]
		local ageProgress = 1 - (age / self.trailLength)
		local distanceProgress = 1 - (offset / math.max(self.count - 1, 1))
		local visibility = ageProgress * (self.DISTANCE_FADE + ((1 - self.DISTANCE_FADE) * distanceProgress))
		local scale = self.DOT_MIN_SCALE + ((1 - self.DOT_MIN_SCALE) * visibility)
		local hue = (dot.distance or 0) / self.RAINBOW_CYCLE_DISTANCE
		local r, g, b = HSVToRGB(hue, self.COLOR_SATURATION, self.COLOR_VALUE)

		texture:ClearAllPoints()
		texture:SetPoint("CENTER", self.frame, "BOTTOMLEFT", dot.x + self.OFFSET_X, dot.y + self.OFFSET_Y)
		texture:SetSize(self.DOT_BASE_SIZE * scale, self.DOT_BASE_SIZE * scale)
		texture:SetVertexColor(r, g, b)
		texture:SetAlpha(self.DOT_ALPHA * visibility)
		texture:Show()
		visible = visible + 1
	end

	for index = visible + 1, self.MAX_DOTS do
		self.textures[index]:Hide()
	end

	if self.headTexture and self.lastCursorX and self.lastCursorY and (visible > 0 or (now - (self.lastMotionTime or 0)) <= self.trailLength) then
		local r, g, b = HSVToRGB(self.cursorDistance / self.RAINBOW_CYCLE_DISTANCE, self.COLOR_SATURATION, self.COLOR_VALUE)
		self.headTexture:ClearAllPoints()
		self.headTexture:SetPoint("CENTER", self.frame, "BOTTOMLEFT", self.lastCursorX + self.OFFSET_X, self.lastCursorY + self.OFFSET_Y)
		self.headTexture:SetSize(self.HEAD_SIZE, self.HEAD_SIZE)
		self.headTexture:SetVertexColor(r, g, b)
		self.headTexture:SetAlpha(self.HEAD_ALPHA)
		self.headTexture:Show()
		headVisible = true
	else
		self.headTexture:Hide()
	end

	self.dormant = (visible == 0) and not headVisible
end

function CursorTracer:EmitInterpolatedDots(startX, startY, endX, endY, now, startDistance)
	local dx = endX - startX
	local dy = endY - startY
	local distanceSq = (dx * dx) + (dy * dy)

	if distanceSq < self.MIN_MOVE_THRESHOLD_SQ then
		return false, startDistance
	end

	local traveled = math.sqrt(distanceSq)
	local consumed = 0
	local emitted = false

	while (traveled - consumed) >= self.remainingToNextDot do
		consumed = consumed + self.remainingToNextDot
		local t = consumed / traveled
		self:PushDot(startX + (dx * t), startY + (dy * t), now, startDistance + consumed)
		self.remainingToNextDot = self.DOT_SPACING
		emitted = true
	end

	self.remainingToNextDot = self.remainingToNextDot - (traveled - consumed)
	if self.remainingToNextDot <= 0 then
		self.remainingToNextDot = self.DOT_SPACING
	end

	return emitted, startDistance + traveled
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

	local moved, newCursorDistance = self:EmitInterpolatedDots(self.lastCursorX, self.lastCursorY, x, y, now, self.cursorDistance)
	self.cursorDistance = newCursorDistance or self.cursorDistance
	self.lastCursorX = x
	self.lastCursorY = y

	if moved then
		self.lastMotionTime = now
		self.dormant = false
	end

	self:RefreshTrail(now)
end
