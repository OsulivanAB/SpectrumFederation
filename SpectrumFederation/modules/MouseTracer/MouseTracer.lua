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
	edgeSoftness = C.DEFAULT_EDGE_SOFTNESS,
	scale = 1,
}

local engine
local host
local stamps
local stampLastAlpha
-- Per-slot last applied appearance identity (texture/mask/blend). Kept small and
-- complete so soft transitions cannot leave a stale hard mask or ADD blend.
local stampAppliedTexture
local stampAppliedMask
local stampAppliedBlend
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

-- Resolved once per effective softness change. Sampling/fading reuse these
-- references and never format paths or read the settings Store.
local appearance = {
	softness = nil,
	texture = nil,
	mask = nil,
	blend = nil,
}

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
	elseif key == "edgeSoftness" then
		return Engine.NormalizeEdgeSoftness(value)
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
	snap.edgeSoftness = cache.edgeSoftness
	local store = SF.SettingsStore
	if store and store.Set then
		store:Set("mouseTracerCopies", copies)
	end
end

local snapshotTimerGen = 0

local function CancelSnapshotTimer()
	snapshotTimerGen = snapshotTimerGen + 1
	local handle = snapshotTicker
	snapshotTicker = nil
	if not handle then
		return
	end
	-- Retail NewTimer returns FunctionContainer userdata, not a table.
	pcall(function() handle:Cancel() end)
end

-- C_Timer.After does not return a cancellable handle. Prefer NewTimer, and
-- keep a pending marker plus generation so After callbacks can still coalesce
-- and become no-ops after cancel/disable.
local function StartSnapshotTimer(delay, callback)
	if C_Timer and C_Timer.NewTimer then
		snapshotTicker = C_Timer.NewTimer(delay, callback)
		return snapshotTicker ~= nil
	end
	if C_Timer and C_Timer.After then
		snapshotTicker = { after = true }
		C_Timer.After(delay, callback)
		return true
	end
	return false
end

function Tracer:FlushSnapshot()
	CancelSnapshotTimer()
	snapshotDirty = false
	self:PersistSnapshot()
end

function Tracer:ScheduleSnapshot()
	snapshotDirty = true
	snapshotDue = Now() + C.SNAPSHOT_DEBOUNCE
	if snapshotTicker then
		return
	end

	local gen = snapshotTimerGen

	local function FireSnapshot()
		if gen ~= snapshotTimerGen then
			return
		end
		snapshotTicker = nil
		if not snapshotDirty then
			return
		end
		local remaining = snapshotDue - Now()
		if remaining > 0.01 then
			if not StartSnapshotTimer(remaining, FireSnapshot) then
				snapshotDirty = false
				Tracer:PersistSnapshot()
			end
			return
		end
		snapshotDirty = false
		Tracer:PersistSnapshot()
	end

	if not StartSnapshotTimer(C.SNAPSHOT_DEBOUNCE, FireSnapshot) then
		snapshotDirty = false
		self:PersistSnapshot()
	end
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

local function TrailDistRange()
	local newest = engine:ChronoIndex(engine.count)
	local oldest = engine:ChronoIndex(1)
	local newestDist = newest and engine.pdist[newest] or 0
	local oldestDist = oldest and engine.pdist[oldest] or 0
	return newestDist, oldestDist
end

local function StampSize(idx, newestDist, oldestDist)
	return Engine.TaperedSize(cache.thickness, newestDist, oldestDist, engine.pdist[idx])
end

-- Resolve cached appearance from cache.edgeSoftness. Returns true when the
-- effective texture/mask/blend identity changed and visual work is required.
local function SyncAppearanceCache()
	local softness, texture, mask, blend = Engine.StampAppearanceForEdgeSoftness(cache.edgeSoftness)
	if appearance.softness == softness
		and appearance.texture == texture
		and appearance.mask == mask
		and appearance.blend == blend then
		return false
	end
	appearance.softness = softness
	appearance.texture = texture
	appearance.mask = mask
	appearance.blend = blend
	return true
end

-- Apply the cached appearance to one stamp when its identity is stale.
-- Each property is compared independently so nonzero→nonzero texture swaps do
-- not reissue unchanged SetMask / SetBlendMode calls.
-- Returns true when any texture/mask/blend write occurred.
local function ApplyStampAppearance(stamp, idx)
	if not stamp or not idx then
		return false
	end
	local texture = appearance.texture
	local mask = appearance.mask
	local blend = appearance.blend
	if not texture then
		return false
	end
	local changed = false
	if stampAppliedTexture[idx] ~= texture then
		if stamp.SetTexture then
			stamp:SetTexture(texture)
		end
		stampAppliedTexture[idx] = texture
		changed = true
	end
	-- mask is always a string identity here: CIRCLE_TEXTURE or CLEARED_MASK ("").
	-- Do not treat "" as absent — Retail requires SetMask("") to clear a legacy mask.
	if stampAppliedMask[idx] ~= mask then
		if stamp.SetMask then
			pcall(stamp.SetMask, stamp, mask)
		end
		stampAppliedMask[idx] = mask
		changed = true
	end
	if stampAppliedBlend[idx] ~= blend then
		if stamp.SetBlendMode and blend then
			pcall(stamp.SetBlendMode, stamp, blend)
		end
		stampAppliedBlend[idx] = blend
		changed = true
	end
	return changed
end

-- Softness-only updates refresh live stamps. Hidden slots stay stale until
-- PlaceStamp / reuse applies the cached appearance before Show.
local function RefreshLiveStampAppearances()
	if not poolReady or not engine or not stamps then
		return
	end
	for chrono = 1, engine.count do
		local idx = engine:ChronoIndex(chrono)
		if idx then
			ApplyStampAppearance(stamps[idx], idx)
		end
	end
end

local function PlaceStamp(idx, newestDist, oldestDist)
	if not host or not stamps or not idx or idx < 1 then
		return
	end
	local stamp = stamps[idx]
	if not stamp then
		return
	end
	-- Ring-buffer reuse and first show must adopt the latest appearance before
	-- becoming visible. Softness-only changes never reset alpha or birth time.
	ApplyStampAppearance(stamp, idx)
	if newestDist == nil or oldestDist == nil then
		newestDist, oldestDist = TrailDistRange()
	end
	local size = StampSize(idx, newestDist, oldestDist)
	local r, g, b = Engine.HSVToRGB(engine.pdist[idx] * C.HUE_PER_PIXEL * cache.rainbowSpeed, 1, 1)
	stamp:SetPoint("CENTER", host, "BOTTOMLEFT", engine.px[idx], engine.py[idx])
	stamp:SetSize(size, size)
	if stamp.SetVertexColor then
		stamp:SetVertexColor(r, g, b, 1)
	end
	local alreadyShown = stamp.IsShown and stamp:IsShown()
	if not alreadyShown then
		stamp:SetAlpha(cache.opacity)
		stampLastAlpha[idx] = cache.opacity
	end
	stamp:Show()
end

local function RefreshLiveStampSizes(newestDist, oldestDist)
	if not stamps then
		return
	end
	if newestDist == nil or oldestDist == nil then
		newestDist, oldestDist = TrailDistRange()
	end
	for chrono = 1, engine.count do
		local idx = engine:ChronoIndex(chrono)
		local stamp = idx and stamps[idx]
		if stamp then
			local size = StampSize(idx, newestDist, oldestDist)
			stamp:SetSize(size, size)
		end
	end
end

local function ApplyReleased()
	-- Always hide released slots, including indices that wrap and become
	-- live again this tick. PlaceStamp then treats them as new and restores
	-- full opacity. Skipping hide would leave the newest stamp at the tail's faded alpha.
	for i = 1, engine.releasedPointCount do
		HideStamp(engine.releasedPoints[i])
	end
	engine.releasedCount = 0
	engine.releasedPointCount = 0
end

local function ApplyNewStamps()
	if not host or not stamps then
		return
	end
	local newestDist, oldestDist = TrailDistRange()
	for i = 1, engine.newSegCount do
		local id = engine.newSegs[i]
		if engine.segActive[id] then
			local i0 = engine.segI0[id]
			local i1 = engine.segI1[id]
			if engine:IsLiveIndex(i0) then
				PlaceStamp(i0, newestDist, oldestDist)
			end
			if engine:IsLiveIndex(i1) then
				PlaceStamp(i1, newestDist, oldestDist)
			end
		end
	end
	RefreshLiveStampSizes(newestDist, oldestDist)
	engine.newSegCount = 0
end

local function UpdateAlphas(now)
	if not stamps then
		return
	end
	local fadeDuration = cache.fadeDuration
	local opacity = cache.opacity
	local epsilon = C.ALPHA_EPSILON
	local newestDist, oldestDist = TrailDistRange()
	for chrono = 1, engine.count do
		local idx = engine:ChronoIndex(chrono)
		if idx then
			local alpha = opacity * Engine.FadeFactor(now - engine.pt[idx], fadeDuration)
			local stamp = stamps[idx]
			if alpha <= 0 then
				HideStamp(idx)
			elseif stamp then
				local size = StampSize(idx, newestDist, oldestDist)
				stamp:SetSize(size, size)
				if math.abs(alpha - (stampLastAlpha[idx] or 0)) > epsilon then
					stamp:SetAlpha(alpha)
					stampLastAlpha[idx] = alpha
				end
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

-- One next-frame confirmation for a coordinate-space transition. The scale
-- read inside DISPLAY_SIZE_CHANGED / UI_SCALE_CHANGED can still be the
-- pre-change value. A resize drag can emit a burst of those events; the
-- stamp pool and segment arrays are cleared once, not on every event.
local scaleRefreshPending = false

local function ScalesDiffer(previous, current)
	previous = previous or 0
	current = current or 0
	local diff = previous - current
	if diff < 0 then
		diff = -diff
	end
	return diff > 0.0001
end

local function HasLiveTrail()
	return engine and (engine.count > 0 or (engine.activeSegCount or 0) > 0)
end

local function DropSamplingBaseline()
	if engine then
		engine:InvalidateBaseline()
	end
	lastRawX = nil
	lastRawY = nil
end

-- Full pool reset only when stamps or segments are actually live. A baseline
-- alone is an O(1) invalidation. Disabled transitions only refresh the cache:
-- StopRuntime has already cleared the trail.
local function ApplyCoordinateDiscontinuity(allowPoolReset)
	if not cache.enabled or not engine then
		return
	end
	if allowPoolReset and HasLiveTrail() then
		Tracer:OnDiscontinuity(true)
	elseif engine.hasBaseline then
		DropSamplingBaseline()
	else
		lastRawX = nil
		lastRawY = nil
	end
end

local function RefreshCoordinateSpace()
	local previous = cache.scale
	RecacheScale()
	local scaleChanged = ScalesDiffer(previous, cache.scale)

	if not scaleRefreshPending then
		ApplyCoordinateDiscontinuity(true)
	elseif scaleChanged then
		ApplyCoordinateDiscontinuity(true)
	end

	if scaleRefreshPending or not C_Timer or not C_Timer.After then
		return
	end
	scaleRefreshPending = true
	C_Timer.After(0, function()
		scaleRefreshPending = false
		local before = cache.scale
		RecacheScale()
		if not ScalesDiffer(before, cache.scale) then
			return
		end
		ApplyCoordinateDiscontinuity(true)
	end)
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
	stampAppliedTexture = {}
	stampAppliedMask = {}
	stampAppliedBlend = {}
	SyncAppearanceCache()
	for idx = 1, C.MAX_POINTS do
		local stamp = host:CreateTexture(nil, "ARTWORK")
		ApplyStampAppearance(stamp, idx)
		stamp:SetSize(cache.thickness, cache.thickness)
		stamp:Hide()
		stamps[idx] = stamp
		stampLastAlpha[idx] = 0
	end

	RecacheScale()
	poolReady = true
end

local function StopRuntime()
	CancelSnapshotTimer()
	if host then
		host:SetScript("OnUpdate", nil)
		host:Hide()
	end
	HideAllStamps()
	if engine then
		engine:Reset()
		engine:SetConfig(cache.trailLength, cache.fadeDuration, cache.rainbowSpeed, cache.thickness)
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
		engine:SetConfig(cache.trailLength, cache.fadeDuration, cache.rainbowSpeed, cache.thickness)
	end
end

local function ReconfigureActiveStamps()
	if not poolReady or not engine or not stamps then
		return
	end
	local newestDist, oldestDist = TrailDistRange()
	for chrono = 1, engine.count do
		local idx = engine:ChronoIndex(chrono)
		if idx then
			PlaceStamp(idx, newestDist, oldestDist)
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
	cache.edgeSoftness = ClampSetting("edgeSoftness", store:GetCharacter("mouseTracer.edgeSoftness"))
	SyncEngineConfig()
	SyncAppearanceCache()
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

	if key == "trailLength" or key == "fadeDuration" or key == "rainbowSpeed" or key == "thickness" then
		SyncEngineConfig()
	end
	if key == "edgeSoftness" then
		-- Resolve once. Skip redundant work when the normalized appearance is
		-- unchanged. Softness-only updates refresh live stamps' texture/mask/
		-- blend without reconfiguring geometry or resetting fade alpha.
		if SyncAppearanceCache() then
			RefreshLiveStampAppearances()
		end
	end
	if engine and engine.count > 0 then
		if key == "trailLength" or key == "fadeDuration" then
			engine:ProcessFade(Now())
			ApplyReleased()
		end
		if key == "rainbowSpeed" or key == "thickness" or key == "opacity" or key == "fadeDuration" or key == "trailLength" then
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

function Tracer.IsCopySelectionEnabled(sourceId, options)
	if type(sourceId) ~= "string" or sourceId == "" then
		return false
	end
	if type(options) ~= "table" then
		return false
	end
	for i = 1, #options do
		local opt = options[i]
		local value = opt
		if type(opt) == "table" then
			value = opt.value
		end
		if value == sourceId then
			return true
		end
	end
	return false
end

function Tracer:CanCopy()
	return Tracer.IsCopySelectionEnabled(self:GetCopySource(), self:GetCopyOptions())
end

function Tracer:GetCopySource()
	return copySource
end

function Tracer:SetCopySource(value)
	if type(value) == "string" and value ~= "" then
		copySource = value
	else
		copySource = nil
	end
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

	-- Always write every Mouse Tracer key. Missing fields in older snapshots
	-- resolve through ClampSetting defaults (edgeSoftness → 50%) so the
	-- destination cannot keep a stale softness value.
	applySuspended = true
	for i = 1, #KEYS do
		local key = KEYS[i]
		store:SetCharacter("mouseTracer." .. key, ClampSetting(key, src[key]))
	end
	applySuspended = false

	self:ReloadCacheFromStore()
	SyncAppearanceCache()
	self:ApplyEnabled(cache.enabled)
	if cache.enabled and engine and engine.count > 0 then
		RefreshLiveStampAppearances()
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
		engine:SetConfig(cache.trailLength, cache.fadeDuration, cache.rainbowSpeed, cache.thickness)
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
			-- ResetAll only emits sf.reset, not per-key edgeSoftness.
			-- ReloadCacheFromStore resolves appearance (softness → 0) so re-enable
			-- / reuse applies the original hard circular stamps before Show.
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
		events:RegisterEvent("DISPLAY_SIZE_CHANGED")
		pcall(events.RegisterEvent, events, "UI_SCALE_CHANGED")
		events:SetScript("OnEvent", function(_, event)
			if event == "PLAYER_LOGIN" then
				self:ReloadCacheFromStore()
				self:ApplyEnabled(cache.enabled)
				self:FlushSnapshot()
			elseif event == "PLAYER_ENTERING_WORLD" or event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
				-- Windowed alt-tab and resizes fire DISPLAY_SIZE_CHANGED when
				-- the cursor-to-UI scale changes without UI_SCALE_CHANGED.
				RefreshCoordinateSpace()
			elseif event == "PLAYER_LOGOUT" then
				self:FlushSnapshot()
			end
		end)
		self._eventFrame = events
	end

	DebugInfo("Mouse Tracer module initialized")
end

-- Temporary Retail diagnostic for issue #454. Fresh SoftCircle_100 samples with
-- true no-mask (SetMask never called), ADD/no-mask, and ADD/circular-mask, plus
-- overlapping copies under the same three conditions. Fixed roles reuse one
-- panel/texture set; Clear only hides. Remove after Retail confirmation.
-- Invoke: /run SpectrumFederation.MouseTracer:RunEdgeSoftnessDiagnostic()
-- Dismiss: /run SpectrumFederation.MouseTracer:ClearEdgeSoftnessDiagnostic()
local softnessDiag

local function SoftnessDiagText(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default
end

local function SoftnessDiagProbeTexture(tex, softPath, blend, maskPath, label)
	local texOk = false
	local texPath = nil
	if tex.SetTexture then
		local setResult = tex:SetTexture(softPath)
		texOk = setResult ~= false
	end
	if tex.GetTexture then
		texPath = tex:GetTexture()
		texOk = texPath ~= nil and texPath ~= ""
	else
		texPath = softPath
	end

	local maskCalled = maskPath ~= nil
	local maskOk = true
	local maskErr = nil
	if maskCalled then
		if tex.SetMask then
			maskOk, maskErr = pcall(tex.SetMask, tex, maskPath)
		else
			maskOk = false
			maskErr = "SetMask unavailable"
		end
	end

	local blendOk = false
	local actualBlend = nil
	if tex.SetBlendMode then
		blendOk = pcall(tex.SetBlendMode, tex, blend)
	end
	if tex.GetBlendMode then
		actualBlend = tex:GetBlendMode()
	else
		actualBlend = blend
	end

	DebugInfo(
		"softness-diag %s texture=%s texOk=%s texPath=%s maskRequested=%s maskCalled=%s maskOk=%s maskErr=%s blendWant=%s blendOk=%s blendActual=%s",
		label,
		tostring(softPath),
		tostring(texOk),
		tostring(texPath),
		tostring(maskPath),
		tostring(maskCalled),
		tostring(maskOk),
		tostring(maskErr),
		tostring(blend),
		tostring(blendOk),
		tostring(actualBlend)
	)
end

local function EnsureSoftnessDiagnostic()
	if softnessDiag and softnessDiag.root then
		return softnessDiag
	end
	if not CreateFrame or not UIParent then
		return nil
	end

	local root = CreateFrame("Frame", "SF_MouseTracerSoftnessDiag", UIParent)
	root:SetFrameStrata("TOOLTIP")
	root:SetFrameLevel(20000)
	root:SetSize(520, 280)
	root:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	root:EnableMouse(true)
	if root.SetBackdrop then
		root:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
		})
		root:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
		root:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	else
		local bg = root:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(root)
		bg:SetColorTexture(0.05, 0.05, 0.05, 0.95)
	end

	local title = root:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", root, "TOP", 0, -8)

	local hint = root:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOM", root, "BOTTOM", 0, 8)
	hint:SetWidth(500)

	-- Fixed-role samples. No-mask roles never call SetMask so they stay true
	-- no-mask controls even after repeated show/hide. Overlap groups keep three
	-- copies each under identical blend/mask conditions.
	local roles = {
		{
			key = "blend_none",
			labelKey = "MOUSE_TRACER_SOFTNESS_DIAG_BLEND_NONE",
			labelDefault = "BLEND / no mask",
			blend = "BLEND",
			mask = nil,
			x = 70,
			y = 55,
			overlap = false,
		},
		{
			key = "add_none",
			labelKey = "MOUSE_TRACER_SOFTNESS_DIAG_ADD_NONE",
			labelDefault = "ADD / no mask",
			blend = "ADD",
			mask = nil,
			x = 210,
			y = 55,
			overlap = false,
		},
		{
			key = "add_circle",
			labelKey = "MOUSE_TRACER_SOFTNESS_DIAG_ADD_CIRCLE",
			labelDefault = "ADD / circle mask",
			blend = "ADD",
			mask = C.CIRCLE_TEXTURE,
			x = 350,
			y = 55,
			overlap = false,
		},
		{
			key = "overlap_blend_none",
			labelKey = "MOUSE_TRACER_SOFTNESS_DIAG_OVERLAP_BLEND_NONE",
			labelDefault = "Overlap BLEND / no mask",
			blend = "BLEND",
			mask = nil,
			x = 70,
			y = -55,
			overlap = true,
		},
		{
			key = "overlap_add_none",
			labelKey = "MOUSE_TRACER_SOFTNESS_DIAG_OVERLAP_ADD_NONE",
			labelDefault = "Overlap ADD / no mask",
			blend = "ADD",
			mask = nil,
			x = 210,
			y = -55,
			overlap = true,
		},
		{
			key = "overlap_add_circle",
			labelKey = "MOUSE_TRACER_SOFTNESS_DIAG_OVERLAP_ADD_CIRCLE",
			labelDefault = "Overlap ADD / circle mask",
			blend = "ADD",
			mask = C.CIRCLE_TEXTURE,
			x = 350,
			y = -55,
			overlap = true,
		},
	}

	local samples = {}
	for i = 1, #roles do
		local role = roles[i]
		local group = {
			role = role,
			textures = {},
			caption = root:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
		}
		local copies = role.overlap and 3 or 1
		for copy = 1, copies do
			local tex = root:CreateTexture(nil, "ARTWORK")
			tex:SetSize(64, 64)
			local ox = (copy - 1) * 8
			local oy = (copy - 1) * -6
			tex:SetPoint("CENTER", root, "CENTER", role.x - 260 + ox, role.y + oy)
			group.textures[copy] = tex
		end
		group.caption:SetPoint("TOP", group.textures[1], "BOTTOM", 0, role.overlap and -18 or -6)
		samples[i] = group
	end

	softnessDiag = {
		root = root,
		title = title,
		hint = hint,
		samples = samples,
		configured = false,
	}
	root:Hide()
	return softnessDiag
end

function Tracer:ClearEdgeSoftnessDiagnostic()
	local diag = softnessDiag
	if diag and diag.root then
		diag.root:Hide()
	end
	DebugInfo("Edge Softness diagnostic cleared")
end

function Tracer:RunEdgeSoftnessDiagnostic()
	local diag = EnsureSoftnessDiagnostic()
	if not diag then
		DebugWarn("Edge Softness diagnostic requires CreateFrame/UIParent")
		return
	end

	local softPath = Engine.StampTextureForEdgeSoftness(100)
	diag.title:SetText(SoftnessDiagText(
		"MOUSE_TRACER_SOFTNESS_DIAG_TITLE",
		"Mouse Tracer Softness Diag (temporary #454)"
	))
	diag.hint:SetText(SoftnessDiagText(
		"MOUSE_TRACER_SOFTNESS_DIAG_HINT",
		"Compare isolated and overlapping SoftCircle_100 samples, then the live trail. Clear: /run SpectrumFederation.MouseTracer:ClearEdgeSoftnessDiagnostic()"
	))

	for i = 1, #diag.samples do
		local group = diag.samples[i]
		local role = group.role
		local label = SoftnessDiagText(role.labelKey, role.labelDefault)
		group.caption:SetText(label)
		for copy = 1, #group.textures do
			local tex = group.textures[copy]
			-- Configure mask/blend only once per fixed-role texture so no-mask
			-- samples never receive SetMask on later invocations.
			if not diag.configured then
				SoftnessDiagProbeTexture(tex, softPath, role.blend, role.mask, role.key .. "#" .. copy)
				if tex.SetVertexColor then
					tex:SetVertexColor(1, 0.35, 0.85, 1)
				end
				tex:SetAlpha(0.70)
			elseif tex.SetTexture then
				tex:SetTexture(softPath)
			end
			tex:Show()
		end
	end
	diag.configured = true
	diag.root:Show()
	DebugInfo("Edge Softness diagnostic shown using %s (configured=%s)", tostring(softPath), tostring(diag.configured))
end
