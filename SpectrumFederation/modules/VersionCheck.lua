-- Grab the namespace
local addonName, SF = ...

-- luacheck: globals CreateFrame C_ChatInfo C_Timer GetTime GetNumGroupMembers time
-- luacheck: globals IsInRaid IsInGroup UnitFullName UnitClass UnitExists UnitIsUnit UnitIsConnected
-- luacheck: globals GetRealmName C_AddOns GetAddOnMetadata

-- Lightweight raid/party version roster.
-- Prefix: SF_VER
-- PING:<nonce>:<version>  (broadcast on RAID/PARTY)
-- PONG:<nonce>:<version>  (whispered back to the requester)
SF.VersionCheck = SF.VersionCheck or {}
local VC = SF.VersionCheck

local PREFIX = "SF_VER"
local MSG_PING = "PING"
local MSG_PONG = "PONG"
local REPLY_TIMEOUT_SECONDS = 2.5
local PING_MIN_INTERVAL_SECONDS = 2
local LISTENER_KEY = "version_window"

local function DebugInfo(fmt, ...)
	if SF.Debug then
		SF.Debug:Info("VERSION_CHECK", fmt, ...)
	end
end

local function DebugVerbose(fmt, ...)
	if SF.Debug then
		SF.Debug:Verbose("VERSION_CHECK", fmt, ...)
	end
end

local function DebugWarn(fmt, ...)
	if SF.Debug then
		SF.Debug:Warn("VERSION_CHECK", fmt, ...)
	end
end

local function DebugError(fmt, ...)
	if SF.Debug then
		SF.Debug:Error("VERSION_CHECK", fmt, ...)
	end
end

local function Now()
	return (GetTime and GetTime()) or (time and time()) or 0
end

local function GetOwnVersion()
	if SF.GetAddonVersion then
		return SF:GetAddonVersion() or "Unknown"
	end
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		return C_AddOns.GetAddOnMetadata(addonName, "Version") or "Unknown"
	end
	if GetAddOnMetadata then
		return GetAddOnMetadata(addonName, "Version") or "Unknown"
	end
	return "Unknown"
end

local function SanitizeToken(value, fallback)
	if type(value) ~= "string" then
		return fallback
	end
	value = value:gsub("[\r\n:]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then
		return fallback
	end
	if #value > 64 then
		value = value:sub(1, 64)
	end
	return value
end

local function NormalizeNameRealm(name, realm)
	if not name or name == "" then
		return nil
	end
	local full = name
	if realm and realm ~= "" then
		full = name .. "-" .. realm
	end
	if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
		return SF.NameUtil.NormalizeNameRealm(full) or full
	end
	if realm and realm ~= "" then
		realm = realm:gsub("%s+", "")
		return name .. "-" .. realm
	end
	local defaultRealm = GetRealmName and GetRealmName() or nil
	if defaultRealm then
		defaultRealm = defaultRealm:gsub("%s+", "")
		return name .. "-" .. defaultRealm
	end
	return name
end

local function ShortName(full)
	if type(full) ~= "string" then
		return "Unknown"
	end
	return full:match("^[^%-]+") or full
end

local function SamePlayer(a, b)
	if SF.NameUtil and SF.NameUtil.SamePlayer then
		return SF.NameUtil.SamePlayer(a, b)
	end
	if type(a) ~= "string" or type(b) ~= "string" then
		return false
	end
	return a:lower() == b:lower()
end

local function SelfId()
	if SF.NameUtil and SF.NameUtil.GetSelfId then
		return SF.NameUtil.GetSelfId()
	end
	if SF.GetPlayerFullIdentifier then
		return SF:GetPlayerFullIdentifier()
	end
	local name, realm = UnitFullName and UnitFullName("player")
	return NormalizeNameRealm(name, realm)
end

local function ToWoWHexColor(color)
	if type(color) == "table" then
		local r = tonumber(color.r or color[1] or 1) or 1
		local g = tonumber(color.g or color[2] or 1) or 1
		local b = tonumber(color.b or color[3] or 1) or 1
		r = math.min(math.max(r, 0), 1)
		g = math.min(math.max(g, 0), 1)
		b = math.min(math.max(b, 0), 1)
		return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
	end
	return "|cffffffff"
end

local function ColorizeUnitName(unit, name)
	if not unit or not name or name == "" then
		return name or "Unknown"
	end
	local _, classToken = UnitClass(unit)
	local classData = classToken and SF.WOW_CLASSES and SF.WOW_CLASSES[classToken]
	if classData and classData.colorCode then
		return string.format("%s%s|r", ToWoWHexColor(classData.colorCode), name)
	end
	return name
end

local function CollectUnits()
	local units = {}
	if IsInRaid and IsInRaid() then
		for i = 1, (GetNumGroupMembers() or 0) do
			table.insert(units, "raid" .. i)
		end
	elseif IsInGroup and IsInGroup() then
		for i = 1, (GetNumGroupMembers() or 1) - 1 do
			table.insert(units, "party" .. i)
		end
		table.insert(units, "player")
	else
		table.insert(units, "player")
	end
	return units
end

local function GetGroupDistribution()
	if IsInRaid and IsInRaid() then
		return "RAID"
	end
	if IsInGroup and IsInGroup() then
		return "PARTY"
	end
	return nil
end

local function IsSelfUnit(unit)
	if not unit then
		return false
	end
	if unit == "player" then
		return true
	end
	if UnitIsUnit then
		return UnitIsUnit(unit, "player") and true or false
	end
	return false
end

local function IsUnitOnline(unit)
	if not unit then
		return false
	end
	if IsSelfUnit(unit) then
		return true
	end
	if UnitIsConnected then
		local connected = UnitIsConnected(unit)
		if connected == nil then
			return true
		end
		return connected and true or false
	end
	return true
end

local function GetPeerAddonVersion(id)
	local sync = SF.LootHelperSync
	if not (id and sync and sync.state and type(sync.state.peers) == "table") then
		return nil
	end

	local peer = sync.state.peers[id]
	if type(peer) == "table" and type(peer.addonVersion) == "string" and peer.addonVersion ~= "" and peer.addonVersion ~= "unknown" then
		return peer.addonVersion
	end

	for name, other in pairs(sync.state.peers) do
		if type(other) == "table" and SamePlayer(name, id) then
			if type(other.addonVersion) == "string" and other.addonVersion ~= "" and other.addonVersion ~= "unknown" then
				return other.addonVersion
			end
		end
	end

	return nil
end

function VC:_GetState()
	self._state = self._state or {
		entries = {},
		order = {},
		nonce = 0,
		activeNonce = nil,
		activeRound = 0,
		lastPingAt = 0,
		snapshotVersion = 0,
		lastNotifiedVersion = -1,
		listeners = {},
		timeoutHandle = nil,
		slashRegistered = false,
	}
	return self._state
end

function VC:_MarkDirty()
	local state = self:_GetState()
	state.snapshotVersion = (state.snapshotVersion or 0) + 1
	return state.snapshotVersion
end

function VC:_NotifyListeners(force)
	local state = self:_GetState()
	local version = state.snapshotVersion or 0
	if not force and state.lastNotifiedVersion == version then
		return version
	end

	state.lastNotifiedVersion = version
	for _, callback in pairs(state.listeners) do
		pcall(callback, version)
	end
	return version
end

function VC:RegisterListener(key, callback)
	if not key or type(callback) ~= "function" then
		return
	end
	self:_GetState().listeners[key] = callback
end

function VC:UnregisterListener(key)
	if not key then
		return
	end
	self:_GetState().listeners[key] = nil
end

function VC:_GetOrCreateEntry(id)
	local state = self:_GetState()
	local entry = state.entries[id]
	if not entry then
		entry = {
			id = id,
			name = ShortName(id),
			displayName = ShortName(id),
			class = nil,
			unit = nil,
			online = true,
			status = "missing",
			version = nil,
			answeredRound = 0,
		}
		state.entries[id] = entry
	end
	return entry
end

function VC:_RebuildRoster()
	local state = self:_GetState()
	local seen = {}
	local order = {}

	for _, unit in ipairs(CollectUnits()) do
		if UnitExists and UnitExists(unit) then
			local name, realm = UnitFullName(unit)
			local id = NormalizeNameRealm(name, realm)
			if id then
				local entry = self:_GetOrCreateEntry(id)
				local _, classToken = UnitClass(unit)
				local isNew = entry.unit == nil and entry.answeredRound == 0 and entry.version == nil
				entry.unit = unit
				entry.class = classToken
				entry.name = ShortName(id)
				entry.displayName = ColorizeUnitName(unit, entry.name)
				entry.online = IsUnitOnline(unit)
				if isNew then
					if SamePlayer(id, SelfId()) then
						entry.version = GetOwnVersion()
						entry.status = "known"
						entry.answeredRound = state.activeRound or 0
					elseif entry.online and (state.activeNonce or false) then
						entry.status = "checking"
					elseif not entry.online then
						entry.status = "missing"
					end
				end
				seen[id] = true
				order[#order + 1] = id
			end
		end
	end

	for id, entry in pairs(state.entries) do
		if not seen[id] then
			state.entries[id] = nil
		else
			entry.id = id
		end
	end

	state.order = order
	self:_MarkDirty()
end

function VC:_RecordVersion(id, version, round)
	if type(id) ~= "string" or id == "" then
		return
	end

	version = SanitizeToken(version, nil)
	if not version then
		return
	end

	local entry = self:_GetOrCreateEntry(id)
	entry.version = version
	entry.status = "known"
	if round then
		entry.answeredRound = round
	end
	self:_MarkDirty()
	self:_NotifyListeners()
end

function VC:_NextNonce()
	local state = self:_GetState()
	state.nonce = (state.nonce or 0) + 1
	return string.format("%d-%d", state.nonce, math.floor(Now() * 1000))
end

function VC:_PackMessage(kind, nonce, version)
	return string.format("%s:%s:%s", kind, nonce, SanitizeToken(version, GetOwnVersion()))
end

function VC:_ParseMessage(text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local kind, nonce, version = text:match("^(%u+):([^:]+):(.*)$")
	if not kind or not nonce then
		return nil
	end
	version = SanitizeToken(version, nil)
	return kind, nonce, version
end

function VC:_Send(message, distribution, target)
	if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
		DebugError("SendAddonMessage is unavailable")
		return false
	end
	if type(message) ~= "string" or message == "" or type(distribution) ~= "string" then
		return false
	end

	local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, distribution, target)
	if not ok then
		DebugWarn("Failed to send %s via %s: %s", message, distribution, tostring(result))
		return false
	end
	return result ~= false
end

function VC:_SendPong(target, nonce)
	if type(target) ~= "string" or target == "" or type(nonce) ~= "string" then
		return
	end
	self:_Send(self:_PackMessage(MSG_PONG, nonce, GetOwnVersion()), "WHISPER", target)
end

function VC:_FinishRound(round)
	local state = self:_GetState()
	if state.activeRound ~= round then
		return
	end

	for _, id in ipairs(state.order) do
		local entry = state.entries[id]
		if entry and entry.answeredRound ~= round then
			if SamePlayer(id, SelfId()) then
				entry.version = GetOwnVersion()
				entry.status = "known"
				entry.answeredRound = round
			else
				local seeded = GetPeerAddonVersion(id)
				if seeded then
					entry.version = seeded
					entry.status = "known"
				else
					entry.version = nil
					entry.status = "missing"
				end
			end
		end
	end

	-- Drop the round nonce so idle roster updates do not keep treating the
	-- last query as in-progress (new joiners would otherwise stay "checking",
	-- and RequestRefresh would keep applying the in-flight ping throttle).
	if state.timeoutHandle and state.timeoutHandle.Cancel then
		pcall(function()
			state.timeoutHandle:Cancel()
		end)
	end
	state.timeoutHandle = nil
	state.activeNonce = nil

	DebugInfo("Version check round %d finished (%d players)", round, #state.order)
	self:_MarkDirty()
	self:_NotifyListeners(true)
end

function VC:_ScheduleRoundTimeout(round)
	local state = self:_GetState()
	if state.timeoutHandle and state.timeoutHandle.Cancel then
		pcall(function()
			state.timeoutHandle:Cancel()
		end)
	end
	state.timeoutHandle = nil

	local function expire()
		local current = self:_GetState()
		current.timeoutHandle = nil
		self:_FinishRound(round)
	end

	if C_Timer and C_Timer.NewTimer then
		state.timeoutHandle = C_Timer.NewTimer(REPLY_TIMEOUT_SECONDS, expire)
	elseif C_Timer and C_Timer.After then
		C_Timer.After(REPLY_TIMEOUT_SECONDS, expire)
	else
		expire()
	end
end

function VC:RequestRefresh(reason)
	self:EnsureSupport()
	self:_RebuildRoster()

	local state = self:_GetState()
	local now = Now()
	if (now - (state.lastPingAt or 0)) < PING_MIN_INTERVAL_SECONDS and state.activeNonce then
		self:_NotifyListeners(true)
		return
	end

	local round = (state.activeRound or 0) + 1
	local nonce = self:_NextNonce()
	state.activeRound = round
	state.activeNonce = nonce
	state.lastPingAt = now

	local me = SelfId()
	local ownVersion = GetOwnVersion()
	for _, id in ipairs(state.order) do
		local entry = state.entries[id]
		if entry then
			if SamePlayer(id, me) then
				entry.version = ownVersion
				entry.status = "known"
				entry.answeredRound = round
				entry.online = true
			else
				local seeded = GetPeerAddonVersion(id)
				if seeded then
					entry.version = seeded
					entry.status = "known"
				end
				if entry.online then
					if entry.answeredRound ~= round then
						entry.status = entry.version and "known" or "checking"
					end
				else
					if not entry.version then
						entry.status = "missing"
					end
					entry.answeredRound = round
				end
			end
		end
	end

	self:_MarkDirty()
	self:_NotifyListeners(true)

	local dist = GetGroupDistribution()
	if dist then
		local sent = self:_Send(self:_PackMessage(MSG_PING, nonce, ownVersion), dist)
		DebugInfo("Broadcast version ping (reason=%s, dist=%s, nonce=%s, sent=%s)", tostring(reason or "manual"), dist, nonce, tostring(sent))
		self:_ScheduleRoundTimeout(round)
	else
		self:_FinishRound(round)
	end
end

function VC:_HandlePing(senderId, nonce, version, whisperTarget)
	if SamePlayer(senderId, SelfId()) then
		return
	end

	local state = self:_GetState()
	self:_RebuildRoster()
	self:_RecordVersion(senderId, version, state.activeRound)
	self:_SendPong(whisperTarget or senderId, nonce)
	DebugVerbose("Responded to version ping from %s (nonce=%s, version=%s)", tostring(senderId), tostring(nonce), tostring(version))
end

function VC:_HandlePong(senderId, nonce, version)
	local state = self:_GetState()
	if state.activeNonce and nonce ~= state.activeNonce then
		return
	end

	self:_RebuildRoster()
	self:_RecordVersion(senderId, version, state.activeRound)
	DebugVerbose("Received version pong from %s (version=%s)", tostring(senderId), tostring(version))
end

function VC:_OnAddonMessage(prefix, text, _, sender)
	if prefix ~= PREFIX or type(text) ~= "string" then
		return
	end

	local senderId = NormalizeNameRealm(sender)
	if not senderId then
		return
	end
	if SamePlayer(senderId, SelfId()) then
		return
	end

	local kind, nonce, version = self:_ParseMessage(text)
	if not kind or not nonce then
		DebugVerbose("Ignored malformed version message from %s", tostring(sender))
		return
	end

	if kind == MSG_PING then
		self:_HandlePing(senderId, nonce, version, sender)
	elseif kind == MSG_PONG then
		self:_HandlePong(senderId, nonce, version)
	end
end

function VC:_OnGroupRosterUpdate()
	self:_RebuildRoster()
	self:_NotifyListeners()

	local window = SF.VersionCheckWindow
	if window and window.IsShown and window:IsShown() then
		self:RequestRefresh("roster_update")
	end
end

function VC:EnsureSupport()
	if self._frame then
		return
	end

	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
		if not ok then
			DebugWarn("RegisterAddonMessagePrefix(%s) failed: %s", PREFIX, tostring(result))
		end
	end

	local frame = CreateFrame("Frame")
	self._frame = frame
	frame:RegisterEvent("CHAT_MSG_ADDON")
	frame:RegisterEvent("GROUP_ROSTER_UPDATE")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:SetScript("OnEvent", function(_, event, ...)
		if event == "CHAT_MSG_ADDON" then
			self:_OnAddonMessage(...)
		elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
			self:_OnGroupRosterUpdate()
		end
	end)

	self:_RebuildRoster()
	DebugInfo("Version check support initialized")
end

function VC:GetSnapshot()
	self:EnsureSupport()
	self:_RebuildRoster()

	local state = self:_GetState()
	local rows = {}
	local knownCount = 0
	local checking = false

	for _, id in ipairs(state.order) do
		local entry = state.entries[id]
		if entry then
			if entry.status == "known" then
				knownCount = knownCount + 1
			elseif entry.status == "checking" then
				checking = true
			end
			rows[#rows + 1] = {
				id = entry.id,
				name = entry.name,
				displayName = entry.displayName or entry.name,
				class = entry.class,
				unit = entry.unit,
				online = entry.online and true or false,
				status = entry.status,
				version = entry.version,
			}
		end
	end

	return {
		version = state.snapshotVersion or 0,
		checking = checking,
		knownCount = knownCount,
		totalCount = #rows,
		ownVersion = GetOwnVersion(),
		rows = rows,
	}
end

function VC:ShowWindow()
	self:EnsureSupport()
	if SF.VersionCheckWindow and SF.VersionCheckWindow.Show then
		SF.VersionCheckWindow:Show()
	else
		if SF.PrintError then
			SF:PrintError("Addon version window is not available.")
		end
		DebugError("VersionCheckWindow is missing")
	end
end

function VC:Enable()
	self:EnsureSupport()

	local state = self:_GetState()
	if not state.slashRegistered and SF.RegisterSlashCommand then
		SF:RegisterSlashCommand("version", function()
			self:ShowWindow()
		end, "Show who in the group is running Spectrum Federation")
		state.slashRegistered = true
		DebugInfo("Registered /sf version")
	end
end

-- Keep a stable listener key for the window without exposing internals.
VC.WINDOW_LISTENER_KEY = LISTENER_KEY
