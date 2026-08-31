-- luacheck: globals CreateFrame UIParent GetCursorPosition GetTime IsMouselooking C_Timer
local _, SF = ...

SF.MouseTracer = SF.MouseTracer or {}
local Tracer = SF.MouseTracer
local C = Tracer.Constants
local Engine = Tracer.TrailEngine

local KEYS = C.SETTING_KEYS

local cache = {
	enabled = false,
	trailLength = C.DEFAULT_TRAIL_LENGTH,
	fadeDuration = C.DEFAULT_FADE_DURATION,
	thickness = C.DEFAULT_THICKNESS,
	rainbowSpeed = C.DEFAULT_RAINBOW_SPEED,
	opacity = C.DEFAULT_OPACITY,
	scale = 1,
}

local engine
local host
local stamps
local stampLastAlpha
local poolReady = false
local applySuspended = false
local sampleElapsed = 0
local fadeElapsed = 0
local lastRawX
local lastRawY
local snapshotDirty = false
local snapshotDue = 0
local snapshotTicker
local copySource
local started = false

local function DebugInfo(message, ...)
	if SF.Debug then
		SF.Debug:Info("MOUSETRACER", message, ...)
	end
end

local function DebugWarn(message, ...)
	if SF.Debug then
		SF.Debug:Warn("MOUSETRACER", message, ...)
	end
end

local function Now()
	if GetTime then
		return GetTime()
	end
	return 0
end

local function ClampSetting(key, value)
	if key == "enabled" then
		return value and true or false
	elseif key == "trailLength" then
		return Engine.ClampNumber(value, C.MIN_TRAIL_LENGTH, C.MAX_TRAIL_LENGTH, C.DEFAULT_TRAIL_LENGTH)
	elseif key == "fadeDuration" then
		return Engine.ClampNumber(value, C.MIN_FADE_DURATION, C.MAX_FADE_DURATION, C.DEFAULT_FADE_DURATION)
	elseif key == "thickness" then
		return Engine.ClampNumber(value, C.MIN_THICKNESS, C.MAX_THICKNESS, C.DEFAULT_THICKNESS)
	elseif key == "rainbowSpeed" then
		return Engine.ClampNumber(value, C.MIN_RAINBOW_SPEED, C.MAX_RAINBOW_SPEED, C.DEFAULT_RAINBOW_SPEED)
	elseif key == "opacity" then
		return Engine.ClampNumber(value, C.MIN_OPACITY, C.MAX_OPACITY, C.DEFAULT_OPACITY)
	end
	return value
end

local function PlayerId()
	if SF.NameUtil and SF.NameUtil.GetSelfId then
		return SF.NameUtil.GetSelfId()
	end
	if SF.GetPlayerFullIdentifier then
		return SF:GetPlayerFullIdentifier()
	end
	return nil
end

local function GetCopiesTable()
	local store = SF.SettingsStore
	if not store or not store.Get then
		return nil
	end
	local copies = store:Get("mouseTracerCopies")
	if type(copies) ~= "table" then
		store:Set("mouseTracerCopies", {})
		copies = store:Get("mouseTracerCopies")
	end
	return copies
end

function Tracer:PersistSnapshot()
	local id = PlayerId()
	if not id then
		return
	end
	local copies = GetCopiesTable()
	if type(copies) ~= "table" then
		return
	end
	local snap = copies[id]
	if type(snap) ~= "table" then
		snap = {}
		copies[id] = snap
	end
	snap.enabled = cache.enabled
	snap.trailLength = cache.trailLength
	snap.fadeDuration = cache.fadeDuration
	snap.thickness = cache.thickness
	snap.rainbowSpeed = cache.rainbowSpeed
	snap.opacity = cache.opacity
	local store = SF.SettingsStore
	if store and store.Set then
		store:Set("mouseTracerCopies", copies)
	end
end

function Tracer:FlushSnapshot()
	snapshotDirty = false
	self:PersistSnapshot()
end

function Tracer:ScheduleSnapshot()
	snapshotDirty = true
	snapshotDue = Now() + C.SNAPSHOT_DEBOUNCE
	if snapshotTicker or not (C_Timer and C_Timer.NewTicker) then
		return
	end
	snapshotTicker = C_Timer.NewTicker(C.SNAPSHOT_TICKER_INTERVAL, function()
		if not snapshotDirty then
			return
		end
		if Now() >= snapshotDue then
			snapshotDirty = false
			Tracer:PersistSnapshot()
		end
	end)
end

local function HideStamp(idx)
	local stamp = stamps and stamps[idx]
	if stamp then
		stamp:Hide()
	end
	if stampLastAlpha then
		stampLastAlpha[idx] = 0
	end
end

local function PlaceStamp(idx)
	if not host or not stamps or not idx then
		return
	end
	local stamp = stamps[idx]
	if not stamp then
		return
	end
	local r, g, b = Engine.HSVToRGB(engine.pdist[idx] * C.HUE_PER_PIXEL * cache.rainbowSpeed, 1, 1)
	stamp:SetPoint("CENTER", host, "BOTTOMLEFT", engine.px[idx], engine.py[idx])
	stamp:SetSize(cache.thickness, cache.thickness)
	if stamp.SetVertexColor then
		stamp:SetVertexColor(r, g, b, 1)
	end
	stamp:SetAlpha(cache.opacity)
	stamp:Show()
	stampLastAlpha[idx] = cache.opacity
end

local function ApplyReleased()
	for i = 1, engine.releasedPointCount do
		local idx = engine.releasedPoints[i]
		if not engine:IsLiveIndex(idx) then
			HideStamp(idx)
		end
	end
	engine.releasedCount = 0
	engine.releasedPointCount = 0
end

local function ApplyNewStamps()
	if not host or not stamps then
		return
	end
	for i = 1, engine.newSegCount do
		local id = engine.newSegs[i]
		PlaceStamp(engine.segI0[id])
		PlaceStamp(engine.segI1[id])
	end
	engine.newSegCount = 0
end

local function UpdateAlphas(now)
	if not stamps then
		return
	end
	local fadeDuration = cache.fadeDuration
	local opacity = cache.opacity
	local epsilon = C.ALPHA_EPSILON
	for chrono = 1, engine.count do
		local idx = engine:ChronoIndex(chrono)
		if idx then
			local alpha = opacity * Engine.FadeFactor(now - engine.pt[idx], fadeDuration)
			local stamp = stamps[idx]
			if alpha <= 0 then
				HideStamp(idx)
			elseif stamp and math.abs(alpha - (stampLastAlpha[idx] or 0)) > epsilon then
				stamp:SetAlpha(alpha)
				stampLastAlpha[idx] = alpha
			end
		end
	end
end

local function HideAllStamps()
	if not stamps then
		return
	end
	for idx = 1, C.MAX_POINTS do
		HideStamp(idx)
	end
end

local function RecacheScale()
	if host and host.GetEffectiveScale then
		local scale = host:GetEffectiveScale()
		if scale and scale > 0 then
			cache.scale = scale
			if engine then
				engine:SetScale(scale)
			end
			return
		end
	end
	if UIParent and UIParent.GetEffectiveScale then
		local scale = UIParent:GetEffectiveScale()
		if scale and scale > 0 then
			cache.scale = scale
			if engine then
				engine:SetScale(scale)
			end
		end
	end
end

local function EnsurePool()
	if poolReady then
		return
	end
	if not CreateFrame or not UIParent then
		return
	end

	host = CreateFrame("Frame", "SF_MouseTracerHost", UIParent)
	host:SetAllPoints(UIParent)
	host:SetFrameStrata("DIALOG")
	host:SetFrameLevel(10000)
	host:EnableMouse(false)
	if host.SetMouseMotionEnabled then
		host:SetMouseMotionEnabled(false)
	end
	if host.SetMouseClickEnabled then
		host:SetMouseClickEnabled(false)
	end
	host:Hide()

	stamps = {}
	stampLastAlpha = {}
	for idx = 1, C.MAX_POINTS do
		local stamp = host:CreateTexture(nil, "ARTWORK")
		if stamp.SetTexture then
			stamp:SetTexture(C.CIRCLE_TEXTURE)
		end
		if stamp.SetMask then
			pcall(stamp.SetMask, stamp, C.CIRCLE_TEXTURE)
		end
		if stamp.SetBlendMode then
			pcall(stamp.SetBlendMode, stamp, "ADD")
		end
		stamp:SetSize(cache.thickness, cache.thickness)
		stamp:Hide()
		stamps[idx] = stamp
		stampLastAlpha[idx] = 0
	end

	RecacheScale()
	poolReady = true
end

local function StopRuntime()
	if host then
		host:SetScript("OnUpdate", nil)
		host:Hide()
	end
	HideAllStamps()
	if engine then
		engine:Reset()
		engine:SetConfig(cache.trailLength, cache.fadeDuration, cache.rainbowSpeed)
		engine:SetScale(cache.scale)
	end
	lastRawX = nil
	lastRawY = nil
	sampleElapsed = 0
	fadeElapsed = 0
	started = false
end

local function DoSample(rawX, rawY, looking)
	engine:ProcessSample(Now(), rawX, rawY, looking)
	ApplyReleased()
	ApplyNewStamps()
end

local function DoFade()
	engine:ProcessFade(Now())
	ApplyReleased()
	UpdateAlphas(Now())
end

local function IsLooking()
	return IsMouselooking and IsMouselooking() or false
end

local function OnUpdate(_, dt)
	if not cache.enabled or not engine then
		return
	end

	sampleElapsed = sampleElapsed + dt
	fadeElapsed = fadeElapsed + dt

	local hasTrail = engine.count > 0
	local sampleDue = sampleElapsed >= (hasTrail and C.ACTIVE_SAMPLE_INTERVAL or C.IDLE_POLL_INTERVAL)
	if sampleDue then
		sampleElapsed = 0
		if GetCursorPosition then
			local rawX, rawY = GetCursorPosition()
			local looking = IsLooking()
			local moved = lastRawX == nil or lastRawY == nil or rawX ~= lastRawX or rawY ~= lastRawY
			if looking or engine.wasMouselook or moved then
				DoSample(rawX, rawY, looking)
			end
			lastRawX = rawX
			lastRawY = rawY
		end
	end

	if hasTrail and fadeElapsed >= C.FADE_INTERVAL then
		fadeElapsed = 0
		DoFade()
	elseif not hasTrail then
		fadeElapsed = 0
	end
end

local function StartRuntime()
	EnsurePool()
	if not host or not engine then
		return
	end
	engine:InvalidateBaseline()
	lastRawX = nil
	lastRawY = nil
	sampleElapsed = 0
	fadeElapsed = 0
	RecacheScale()
	host:Show()
	host:SetScript("OnUpdate", OnUpdate)
	started = true
	DebugInfo("Mouse Tracer enabled")
end

function Tracer:ApplyEnabled(enabled)
	cache.enabled = enabled and true or false
	if cache.enabled then
		StartRuntime()
	else
		if started then
			DebugInfo("Mouse Tracer disabled")
		end
		StopRuntime()
	end
end

local function SyncEngineConfig()
	if engine then
		engine:SetConfig(cache.trailLength, cache.fadeDuration, cache.rainbowSpeed)
	end
end

local function ReconfigureActiveStamps()
	if not poolReady or not engine or not stamps then
		return
	end
	for chrono = 1, engine.count do
		local idx = engine:ChronoIndex(chrono)
		if idx then
			PlaceStamp(idx)
		end
	end
	UpdateAlphas(Now())
end

function Tracer:ReloadCacheFromStore()
	local store = SF.SettingsStore
	if not store or not store.GetCharacter then
		return
	end
	cache.enabled = store:GetCharacter("mouseTracer.enabled") and true or false
	cache.trailLength = ClampSetting("trailLength", store:GetCharacter("mouseTracer.trailLength"))
	cache.fadeDuration = ClampSetting("fadeDuration", store:GetCharacter("mouseTracer.fadeDuration"))
	cache.thickness = ClampSetting("thickness", store:GetCharacter("mouseTracer.thickness"))
	cache.rainbowSpeed = ClampSetting("rainbowSpeed", store:GetCharacter("mouseTracer.rainbowSpeed"))
	cache.opacity = ClampSetting("opacity", store:GetCharacter("mouseTracer.opacity"))
	SyncEngineConfig()
end

local function OnSettingChanged(key, newValue)
	newValue = ClampSetting(key, newValue)
	cache[key] = newValue
	if applySuspended then
		return
	end

	if key == "enabled" then
		Tracer:ApplyEnabled(newValue)
		Tracer:FlushSnapshot()
		return
	end

	if key == "trailLength" or key == "fadeDuration" or key == "rainbowSpeed" then
		SyncEngineConfig()
	end
	if engine and engine.count > 0 then
		if key == "trailLength" or key == "fadeDuration" then
			engine:ProcessFade(Now())
			ApplyReleased()
		end
		if key == "rainbowSpeed" or key == "thickness" or key == "opacity" or key == "fadeDuration" then
			ReconfigureActiveStamps()
		end
	end
	Tracer:ScheduleSnapshot()
end

function Tracer:GetCopyOptions()
	local options = {}
	local copies = GetCopiesTable()
	local selfId = PlayerId()
	if type(copies) ~= "table" then
		return options
	end
	for id, snap in pairs(copies) do
		if type(id) == "string" and type(snap) == "table" then
			local isSelf = false
			if selfId and SF.NameUtil and SF.NameUtil.SamePlayer then
				isSelf = SF.NameUtil.SamePlayer(id, selfId)
			elseif selfId then
				isSelf = id:lower() == selfId:lower()
			end
			if not isSelf then
				table.insert(options, { value = id, label = id })
			end
		end
	end
	table.sort(options, function(a, b)
		return a.label < b.label
	end)
	return options
end

function Tracer:HasCopySources()
	return #self:GetCopyOptions() > 0
end

function Tracer:GetCopySource()
	return copySource
end

function Tracer:SetCopySource(value)
	copySource = value
end

function Tracer:CopyFromCharacter(sourceId)
	local copies = GetCopiesTable()
	if type(copies) ~= "table" or type(copies[sourceId]) ~= "table" then
		return false, "No saved Mouse Tracer settings were found for that character."
	end
	local src = copies[sourceId]
	local store = SF.SettingsStore
	if not store or not store.SetCharacter then
		return false, "Settings storage is not available."
	end

	applySuspended = true
	for i = 1, #KEYS do
		local key = KEYS[i]
		if src[key] ~= nil then
			store:SetCharacter("mouseTracer." .. key, ClampSetting(key, src[key]))
		end
	end
	applySuspended = false

	self:ReloadCacheFromStore()
	self:ApplyEnabled(cache.enabled)
	if cache.enabled and engine and engine.count > 0 then
		ReconfigureActiveStamps()
	end
	self:FlushSnapshot()
	DebugInfo("Copied Mouse Tracer settings from %s", tostring(sourceId))
	return true
end

function Tracer:OnDiscontinuity(clearTrail)
	if clearTrail and engine then
		HideAllStamps()
		engine:Reset()
		engine:SetConfig(cache.trailLength, cache.fadeDuration, cache.rainbowSpeed)
		engine:SetScale(cache.scale)
	elseif engine then
		engine:InvalidateBaseline()
	end
	lastRawX = nil
	lastRawY = nil
end

function Tracer:Init()
	if self.initialized then
		return
	end
	self.initialized = true

	engine = Engine.New()
	self.engine = engine

	local store = SF.SettingsStore
	if store and store.RegisterCallback then
		for i = 1, #KEYS do
			local key = KEYS[i]
			store:RegisterCallback("character.mouseTracer." .. key, function(newValue)
				OnSettingChanged(key, newValue)
			end)
		end
		store:RegisterCallback("sf.reset", function()
			self:ReloadCacheFromStore()
			self:ApplyEnabled(cache.enabled)
			self:FlushSnapshot()
		end)
	end

	self:ReloadCacheFromStore()
	SyncEngineConfig()

	local events = CreateFrame and CreateFrame("Frame") or nil
	if events then
		events:RegisterEvent("PLAYER_LOGIN")
		events:RegisterEvent("PLAYER_ENTERING_WORLD")
		events:RegisterEvent("PLAYER_LOGOUT")
		pcall(events.RegisterEvent, events, "UI_SCALE_CHANGED")
		events:SetScript("OnEvent", function(_, event)
			if event == "PLAYER_LOGIN" then
				self:ReloadCacheFromStore()
				self:ApplyEnabled(cache.enabled)
				self:FlushSnapshot()
			elseif event == "PLAYER_ENTERING_WORLD" then
				RecacheScale()
				self:OnDiscontinuity(true)
			elseif event == "UI_SCALE_CHANGED" then
				RecacheScale()
				self:OnDiscontinuity(true)
			elseif event == "PLAYER_LOGOUT" then
				self:FlushSnapshot()
			end
		end)
		self._eventFrame = events
	end

	DebugInfo("Mouse Tracer module initialized")
end
