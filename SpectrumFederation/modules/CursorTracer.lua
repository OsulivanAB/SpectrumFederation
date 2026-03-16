local addonName, SF = ...

SF.CursorTracer = SF.CursorTracer or {}
local CursorTracer = SF.CursorTracer

CursorTracer.DEFAULT_LENGTH = 12
CursorTracer.MIN_LENGTH = 6
CursorTracer.MAX_LENGTH = 24
CursorTracer.MAX_SEGMENTS = 24
CursorTracer.SAMPLE_INTERVAL = 0.015
CursorTracer.LINE_TEXTURE = "Interface\\Buttons\\WHITE8X8"
CursorTracer.LINE_THICKNESS = 10
CursorTracer.LINE_ALPHA = 0.9
CursorTracer.MIN_SEGMENT_SCALE = 0.55
CursorTracer.SEGMENT_SCALE_RANGE = 0.45
CursorTracer.HUE_SHIFT_SPEED = 0.18
CursorTracer.MOVE_THRESHOLD_SQ = 4

local PI = math.pi

local function ClampLength(value)
	value = tonumber(value) or CursorTracer.DEFAULT_LENGTH
	value = math.floor(value + 0.5)

	if value < CursorTracer.MIN_LENGTH then
		return CursorTracer.MIN_LENGTH
	end
	if value > CursorTracer.MAX_LENGTH then
		return CursorTracer.MAX_LENGTH
	end

	return value
end

local function GetLifeSpan(length)
	return math.max((tonumber(length) or CursorTracer.DEFAULT_LENGTH) * CursorTracer.SAMPLE_INTERVAL, CursorTracer.SAMPLE_INTERVAL)
end

local function GetAngle(dx, dy)
	if dx == 0 then
		if dy >= 0 then
			return PI * 0.5
		end
		return -PI * 0.5
	end

	local angle = math.atan(dy / dx)
	if dx < 0 then
		angle = angle + PI
	end
	return angle
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

	self.enabled = false
	self.length = self.DEFAULT_LENGTH
	self.points = {}
	self.elapsed = 0

	self:EnsureFrame()
	self:HideAll()
end

function CursorTracer:EnsureFrame()
	if self.frame then return end

	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetAllPoints(UIParent)
	frame:SetFrameStrata("HIGH")
	frame:EnableMouse(false)
	frame:Hide()

	self.frame = frame
	self.textures = {}
	self.onUpdate = function(_, elapsed)
		self:OnUpdate(elapsed)
	end

	for index = 1, self.MAX_SEGMENTS do
		local texture = frame:CreateTexture(nil, "OVERLAY")
		texture:SetTexture(self.LINE_TEXTURE)
		texture:SetBlendMode("ADD")
		texture:Hide()
		self.textures[index] = texture
	end
end

function CursorTracer:ApplySettings(settings)
	self:Init()
	settings = settings or {}

	self.length = ClampLength(settings.length)

	if settings.enabled then
		self:SetEnabled(true)
	else
		self:SetEnabled(false)
	end

	if self.enabled then
		self:Refresh()
	end
end

function CursorTracer:SetEnabled(enabled)
	self:Init()
	enabled = not not enabled

	if self.enabled == enabled then return end

	self.enabled = enabled
	if enabled then
		self:Start()
	else
		self:Stop()
	end
end

function CursorTracer:Start()
	if not self.frame then return end

	self.elapsed = 0
	self.frame:Show()
	self.frame:SetScript("OnUpdate", self.onUpdate)
end

function CursorTracer:Stop()
	if self.frame then
		self.frame:SetScript("OnUpdate", nil)
		self.frame:Hide()
	end

	self.elapsed = 0
	self.points = {}
	self:HideAll()
end

function CursorTracer:HideAll()
	for _, texture in ipairs(self.textures or {}) do
		texture:Hide()
	end
end

function CursorTracer:CaptureCursorPoint(age)
	local scale = UIParent:GetEffectiveScale()
	if not scale or scale == 0 then return end

	local x, y = GetCursorPosition()
	x = x / scale
	y = y / scale

	local points = self.points
	local lastPoint = points[1]

	if lastPoint then
		local dx = x - lastPoint.x
		local dy = y - lastPoint.y
		-- Ignore movement smaller than 2px so the trail stays smooth without oversampling.
		if (dx * dx) + (dy * dy) < self.MOVE_THRESHOLD_SQ then
			return
		end
	end

	table.insert(points, 1, {
		x = x,
		y = y,
		age = age or 0,
	})

	while #points > (self.length + 1) do
		table.remove(points)
	end
end

function CursorTracer:AgePoints(delta)
	local points = self.points
	local lifeSpan = GetLifeSpan(self.length)

	for index = #points, 1, -1 do
		local point = points[index]
		point.age = (point.age or 0) + delta

		if index > (self.length + 1) or point.age >= lifeSpan then
			table.remove(points, index)
		end
	end
end

function CursorTracer:Refresh()
	if not self.enabled then
		self:HideAll()
		return
	end

	local points = self.points
	local lifeSpan = GetLifeSpan(self.length)
	local timeOffset = (GetTime and (GetTime() * self.HUE_SHIFT_SPEED)) or 0

	for index = 1, self.MAX_SEGMENTS do
		local texture = self.textures[index]
		local startPoint = points[index]
		local endPoint = points[index + 1]

		if startPoint and endPoint and index <= self.length then
			local dx = startPoint.x - endPoint.x
			local dy = startPoint.y - endPoint.y
			local distanceSq = (dx * dx) + (dy * dy)

			if distanceSq > 0 then
				local distance = math.sqrt(distanceSq)
				local progress = 1 - math.min((((startPoint.age or 0) + (endPoint.age or 0)) * 0.5) / lifeSpan, 1)
				local scale = self.MIN_SEGMENT_SCALE + (progress * self.SEGMENT_SCALE_RANGE)
				local thickness = self.LINE_THICKNESS * scale
				local hue = timeOffset + ((index - 1) / math.max(self.length, 1))
				local r, g, b = HSVToRGB(hue, 0.85, 1)

				texture:ClearAllPoints()
				texture:SetPoint(
					"CENTER",
					self.frame,
					"BOTTOMLEFT",
					(startPoint.x + endPoint.x) * 0.5,
					(startPoint.y + endPoint.y) * 0.5
				)
				texture:SetSize(distance + thickness, thickness)
				texture:SetRotation(GetAngle(dx, dy))
				texture:SetVertexColor(r, g, b)
				texture:SetAlpha(self.LINE_ALPHA * progress)
				texture:Show()
			else
				texture:Hide()
			end
		else
			texture:Hide()
		end
	end
end

function CursorTracer:OnUpdate(elapsed)
	if not self.enabled then return end

	self.elapsed = self.elapsed + (elapsed or 0)
	if self.elapsed < self.SAMPLE_INTERVAL then
		return
	end

	local delta = self.elapsed
	self.elapsed = 0

	self:AgePoints(delta)
	self:CaptureCursorPoint(0)
	self:Refresh()
end
