local addonName, SF = ...

SF.CursorTracer = SF.CursorTracer or {}
local CursorTracer = SF.CursorTracer

CursorTracer.DEFAULT_LENGTH = 12
CursorTracer.MIN_LENGTH = 6
CursorTracer.MAX_LENGTH = 24
CursorTracer.MAX_BLOBS = 96
CursorTracer.SAMPLE_INTERVAL = 0.015
CursorTracer.BLOB_TEXTURE = "Interface\\Cooldown\\ping4"
CursorTracer.BLOB_ALPHA = 0.36
CursorTracer.BLOB_BASE_SIZE = 20
CursorTracer.BLOB_SPACING_FACTOR = 0.32
CursorTracer.MIN_BLOB_SCALE = 0.7
CursorTracer.BLOB_SCALE_RANGE = 0.4
CursorTracer.HUE_SHIFT_SPEED = 0.18
CursorTracer.COLOR_SATURATION = 0.55
CursorTracer.COLOR_VALUE = 0.92
CursorTracer.MOVE_THRESHOLD_SQ = 4

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

	for index = 1, self.MAX_BLOBS do
		local texture = frame:CreateTexture(nil, "OVERLAY")
		texture:SetTexture(self.BLOB_TEXTURE)
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
	local textureIndex = 1

	for index = 1, math.min(#points - 1, self.length) do
		local startPoint = points[index]
		local endPoint = points[index + 1]
		local dx = endPoint.x - startPoint.x
		local dy = endPoint.y - startPoint.y
		local distanceSq = (dx * dx) + (dy * dy)

		if distanceSq > 0 then
			local distance = math.sqrt(distanceSq)
			local startProgress = 1 - math.min((startPoint.age or 0) / lifeSpan, 1)
			local endProgress = 1 - math.min((endPoint.age or 0) / lifeSpan, 1)
			local startSize = self.BLOB_BASE_SIZE * (self.MIN_BLOB_SCALE + (startProgress * self.BLOB_SCALE_RANGE))
			local endSize = self.BLOB_BASE_SIZE * (self.MIN_BLOB_SCALE + (endProgress * self.BLOB_SCALE_RANGE))
			local spacing = math.max(math.min(startSize, endSize) * self.BLOB_SPACING_FACTOR, 2)
			local steps = math.max(1, math.ceil(distance / spacing))

			for step = 0, steps do
				if textureIndex > self.MAX_BLOBS then
					break
				end

				local texture = self.textures[textureIndex]
				local t = step / steps
				local progress = startProgress + ((endProgress - startProgress) * t)
				local scale = self.MIN_BLOB_SCALE + (progress * self.BLOB_SCALE_RANGE)
				local size = self.BLOB_BASE_SIZE * scale
				local hue = timeOffset + ((index - 1 + t) / math.max(self.length, 1))
				local r, g, b = HSVToRGB(hue, self.COLOR_SATURATION, self.COLOR_VALUE)

				texture:ClearAllPoints()
				texture:SetPoint(
					"CENTER",
					self.frame,
					"BOTTOMLEFT",
					startPoint.x + (dx * t),
					startPoint.y + (dy * t)
				)
				texture:SetSize(size, size)
				texture:SetRotation(0)
				texture:SetVertexColor(r, g, b)
				texture:SetAlpha(self.BLOB_ALPHA * progress)
				texture:Show()
				textureIndex = textureIndex + 1
			end

			if textureIndex > self.MAX_BLOBS then
				break
			end
		end
	end

	for index = textureIndex, self.MAX_BLOBS do
		self.textures[index]:Hide()
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
