local addonName, SF = ...

SF.CursorTracer = SF.CursorTracer or {}
local CursorTracer = SF.CursorTracer

CursorTracer.DEFAULT_TEXTURE = "spark"
CursorTracer.DEFAULT_LENGTH = 12
CursorTracer.MIN_LENGTH = 6
CursorTracer.MAX_LENGTH = 24
CursorTracer.SAMPLE_INTERVAL = 0.03
CursorTracer.MOVE_THRESHOLD_SQ = 4
CursorTracer.MAX_SEGMENTS = 24

CursorTracer.TEXTURES = {
	spark = {
		label = "Casting Spark",
		path = "Interface\\CastingBar\\UI-CastingBar-Spark",
		width = 36,
		height = 36,
		blendMode = "ADD",
		r = 1.00,
		g = 0.86,
		b = 0.35,
		alpha = 0.95,
	},
	star = {
		label = "Cooldown Star",
		path = "Interface\\Cooldown\\star4",
		width = 24,
		height = 24,
		blendMode = "ADD",
		r = 0.55,
		g = 0.82,
		b = 1.00,
		alpha = 0.9,
	},
	glow = {
		label = "Soft Glow",
		path = "Interface\\Buttons\\WHITE8X8",
		width = 18,
		height = 18,
		blendMode = "ADD",
		r = 0.65,
		g = 0.95,
		b = 1.00,
		alpha = 0.7,
	},
}

CursorTracer.TEXTURE_ORDER = { "spark", "star", "glow" }

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

function CursorTracer:Init()
	if self.initialized then return end
	self.initialized = true

	self.enabled = false
	self.textureId = self.DEFAULT_TEXTURE
	self.length = self.DEFAULT_LENGTH
	self.points = {}
	self.elapsed = 0

	self:EnsureFrame()
	self:ApplyTexture()
	self:HideAll()
end

function CursorTracer:GetTextureOptions()
	local options = {}

	for _, textureId in ipairs(self.TEXTURE_ORDER) do
		local info = self.TEXTURES[textureId]
		options[#options + 1] = {
			value = textureId,
			label = info and info.label or textureId,
		}
	end

	return options
end

function CursorTracer:GetTextureInfo(textureId)
	return self.TEXTURES[textureId] or self.TEXTURES[self.DEFAULT_TEXTURE]
end

function CursorTracer:EnsureFrame()
	if self.frame then return end

	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetAllPoints(UIParent)
	frame:SetFrameStrata("TOOLTIP")
	frame:EnableMouse(false)
	frame:Hide()

	self.frame = frame
	self.textures = {}

	for index = 1, self.MAX_SEGMENTS do
		local texture = frame:CreateTexture(nil, "OVERLAY")
		texture:Hide()
		self.textures[index] = texture
	end
end

function CursorTracer:ApplyTexture()
	local info = self:GetTextureInfo(self.textureId)

	for _, texture in ipairs(self.textures or {}) do
		texture:SetTexture(info.path)
		texture:SetSize(info.width, info.height)
		texture:SetBlendMode(info.blendMode or "BLEND")
		texture:SetVertexColor(info.r or 1, info.g or 1, info.b or 1, 1)
	end
end

function CursorTracer:ApplySettings(settings)
	self:Init()
	settings = settings or {}

	self.textureId = self.TEXTURES[settings.texture] and settings.texture or self.DEFAULT_TEXTURE
	self.length = ClampLength(settings.length)
	self:ApplyTexture()

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
	enabled = enabled and true or false

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
	self.frame:SetScript("OnUpdate", function(_, elapsed)
		self:OnUpdate(elapsed)
	end)
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
		if (dx * dx) + (dy * dy) < self.MOVE_THRESHOLD_SQ then
			return
		end
	end

	table.insert(points, 1, {
		x = x,
		y = y,
		age = age or 0,
	})

	while #points > self.length do
		points[#points] = nil
	end
end

function CursorTracer:AgePoints(delta)
	local points = self.points
	local lifeSpan = GetLifeSpan(self.length)

	for index = #points, 1, -1 do
		local point = points[index]
		point.age = (point.age or 0) + delta

		if index > self.length or point.age >= lifeSpan then
			table.remove(points, index)
		end
	end
end

function CursorTracer:Refresh()
	if not self.enabled then
		self:HideAll()
		return
	end

	local info = self:GetTextureInfo(self.textureId)
	local lifeSpan = GetLifeSpan(self.length)

	for index = 1, self.MAX_SEGMENTS do
		local texture = self.textures[index]
		local point = self.points[index]

		if point and index <= self.length then
			local progress = 1 - math.min((point.age or 0) / lifeSpan, 1)
			local scale = 0.65 + (progress * 0.35)

			texture:ClearAllPoints()
			texture:SetPoint("CENTER", self.frame, "BOTTOMLEFT", point.x, point.y)
			texture:SetSize(info.width * scale, info.height * scale)
			texture:SetAlpha((info.alpha or 0.85) * progress)
			texture:Show()
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
