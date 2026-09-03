-- TEMPORARY diagnostic child addon.
-- This is not production RC Loot Council integration. It only records logical
-- RC addon communications while a Spectrum Loot Helper session is active.
--
-- Removal checklist (after the SavedVariables file has been uploaded/analyzed):
-- 1. Preserve/upload WTF/Account/<account>/SavedVariables/SpectrumFederation_RCLootCouncilCapture.lua
-- 2. Delete SpectrumFederation_RCLootCouncilCapture/
-- 3. Remove this child addon from packaging/version/lint/docs/test registrations:
--    - .github/scripts/validate_packaging.py
--    - .github/scripts/wow_interface_sync.py
--    - .github/scripts/lint_all.py
--    - .github/scripts/publish_release.py
--    - .github/scripts/update_changelog.py
--    - .github/scripts/validate_docs.py
--    - .github/workflows/pr-beta-validation.yml
--    - .github/workflows/pr-main-validation.yml
--    - .github/workflows/post-merge-beta.yml
--    - .github/workflows/promote-beta-to-main.yml
--    - AGENTS.md, SpectrumFederation/AGENTS.md, docs, README, mkdocs.yml
--    - tests/test_rc_loot_council_capture.py and tests/lua/rc_loot_council_capture_tests.lua
--    - .github/instructions/lua.instructions.md and .cursor/rules/addon-runtime.mdc
-- 4. Optionally delete the user's SavedVariables file after analysis.
--
-- There is no RC capture runtime in the parent addon. The only retained
-- RC-named parent code is legacy snapshot validation for older SavedVariables.

local addonName, ns = ...

ns = ns or {}
ns.RCLootCouncilCapture = ns.RCLootCouncilCapture or {}
local Capture = ns.RCLootCouncilCapture

Capture.ADDON_NAME = addonName or "SpectrumFederation_RCLootCouncilCapture"
Capture.PARENT_ADDON_NAME = "SpectrumFederation"
Capture.SAVED_VARIABLES_GLOBAL = "SpectrumFederationRCLootCouncilCaptureDB"
Capture.SAVED_VARIABLES_FILE = "WTF/Account/<account>/SavedVariables/SpectrumFederation_RCLootCouncilCapture.lua"
Capture.SCHEMA_VERSION = 1
Capture.RECENT_VIEW_LIMIT = 250
Capture.PAGE_ID = "lootHelperRCLootCouncilCapture"
Capture.DEBUG_CATEGORY = "RCLC_CAPTURE"

-- Verified from current evil-morfar/RCLootCouncil2 Core/Constants.lua:
-- addon.PREFIXES = { MAIN = "RCLC", VERSION = "RCLCv", SYNC = "RCLCs" }
Capture.RC_PREFIXES = { "RCLC", "RCLCv", "RCLCs" }

local PREFIX_LOOKUP = {}
for i = 1, #Capture.RC_PREFIXES do
    PREFIX_LOOKUP[Capture.RC_PREFIXES[i]] = true
end

local commReceiver = {
    _registered = false,
    _registerCount = 0,
    _prefixRegisterCounts = {},
}

local recentEntries = {}
local uiDirty = false
local uiRefreshPending = false
local showFullHistory = false
local captureActive = false
local hooksInstalled = false
local initialized = false
local settingsPanel = nil
local pageRegistered = false

local function ParentAddon()
    return _G[Capture.PARENT_ADDON_NAME]
end

local function DebugInfo(message, ...)
    local SF = ParentAddon()
    if SF and SF.Debug then
        SF.Debug:Info(Capture.DEBUG_CATEGORY, message, ...)
    end
end

local function DebugWarn(message, ...)
    local SF = ParentAddon()
    if SF and SF.Debug then
        SF.Debug:Warn(Capture.DEBUG_CATEGORY, message, ...)
    end
end

function Capture.IsKnownPrefix(prefix)
    return type(prefix) == "string" and PREFIX_LOOKUP[prefix] == true
end

function Capture.CopyPrefixList()
    local copied = {}
    for i = 1, #Capture.RC_PREFIXES do
        copied[i] = Capture.RC_PREFIXES[i]
    end
    return copied
end

function Capture.GetSavedVariablesFileHint()
    return Capture.SAVED_VARIABLES_FILE
end

function Capture.Now()
    local SF = ParentAddon()
    if SF and SF.Now then
        return SF:Now()
    end
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

function Capture.GetRelativeTime()
    if GetTime then
        return GetTime()
    end
    return nil
end

function Capture.GetAddonVersion(name)
    name = name or Capture.ADDON_NAME
    local getMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    if type(getMeta) == "function" then
        local ok, value = pcall(getMeta, name, "Version")
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

function Capture.GetLocalPlayerId()
    local SF = ParentAddon()
    if SF and SF.NameUtil and SF.NameUtil.GetSelfId then
        local ok, value = pcall(SF.NameUtil.GetSelfId)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    if UnitName then
        local name = UnitName("player")
        if type(name) == "string" and name ~= "" then
            if GetRealmName then
                local realm = GetRealmName()
                if type(realm) == "string" and realm ~= "" then
                    return name .. "-" .. realm:gsub("%s+", "")
                end
            end
            return name
        end
    end
    return nil
end

function Capture.IsSpectrumSessionActive()
    local SF = ParentAddon()
    local sync = SF and SF.LootHelperSync
    if not (sync and sync.IsSessionActive) then
        return false
    end
    local ok, active = pcall(sync.IsSessionActive, sync)
    return ok and active == true
end

function Capture.GetSessionContext()
    local SF = ParentAddon()
    local sync = SF and SF.LootHelperSync
    local context = {
        sessionActive = Capture.IsSpectrumSessionActive(),
        sessionId = nil,
        profileId = nil,
        coordinator = nil,
    }
    if not context.sessionActive or not sync then
        return context
    end
    if sync.GetSessionId then
        local ok, value = pcall(sync.GetSessionId, sync)
        if ok then
            context.sessionId = value
        end
    end
    if sync.GetSessionProfileId then
        local ok, value = pcall(sync.GetSessionProfileId, sync)
        if ok then
            context.profileId = value
        end
    end
    if sync.GetCoordinator then
        local ok, value = pcall(sync.GetCoordinator, sync)
        if ok then
            context.coordinator = value
        end
    end
    return context
end

local UNSUPPORTED = {
    ["function"] = true,
    ["userdata"] = true,
    ["thread"] = true,
}

function Capture.NormalizeForSavedVariables(value, seen)
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
        return value
    end
    if UNSUPPORTED[valueType] then
        return string.format("<%s>", valueType)
    end
    if valueType ~= "table" then
        return string.format("<%s>", valueType)
    end

    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true

    local copied = {}
    for key, nested in pairs(value) do
        local keyType = type(key)
        local safeKey
        if keyType == "string" or keyType == "number" then
            safeKey = key
        else
            safeKey = string.format("<%s>", keyType)
        end
        copied[safeKey] = Capture.NormalizeForSavedVariables(nested, seen)
    end

    seen[value] = nil
    return copied
end

function Capture.EnsureDatabase(existing)
    if type(existing) ~= "table" then
        return {
            schemaVersion = Capture.SCHEMA_VERSION,
            nextSequence = 1,
            entries = {},
        }
    end

    local entries = existing.entries
    if type(entries) ~= "table" then
        entries = {}
        existing.entries = entries
    end

    local maxSequence = 0
    for i = 1, #entries do
        local entry = entries[i]
        if type(entry) == "table" and type(entry.sequence) == "number" and entry.sequence > maxSequence then
            maxSequence = entry.sequence
        end
    end

    local nextSequence = existing.nextSequence
    if type(nextSequence) ~= "number" or nextSequence ~= nextSequence or nextSequence < 1 then
        nextSequence = maxSequence + 1
    end
    if nextSequence <= maxSequence then
        nextSequence = maxSequence + 1
    end

    existing.schemaVersion = Capture.SCHEMA_VERSION
    existing.nextSequence = nextSequence
    existing.entries = entries
    return existing
end

function Capture.GetDatabase()
    local globalName = Capture.SAVED_VARIABLES_GLOBAL
    local existing = rawget(_G, globalName)
    local db = Capture.EnsureDatabase(existing)
    rawset(_G, globalName, db)
    return db
end

function Capture.CountEntries(db)
    db = db or Capture.GetDatabase()
    local entries = db and db.entries
    if type(entries) ~= "table" then
        return 0, 0
    end
    local total = #entries
    local messages = 0
    for i = 1, total do
        local entry = entries[i]
        if type(entry) == "table" and entry.kind == "message" then
            messages = messages + 1
        end
    end
    return total, messages
end

function Capture.GetLatestTimestamp(db)
    db = db or Capture.GetDatabase()
    local entries = db and db.entries
    if type(entries) ~= "table" or #entries == 0 then
        return nil
    end
    for i = #entries, 1, -1 do
        local entry = entries[i]
        if type(entry) == "table" and type(entry.timestamp) == "number" then
            return entry.timestamp
        end
    end
    return nil
end

function Capture.AppendEntry(db, entry)
    db = Capture.EnsureDatabase(db)
    if type(entry) ~= "table" then
        return nil
    end

    local sequence = db.nextSequence
    entry.sequence = sequence
    db.nextSequence = sequence + 1
    db.entries[#db.entries + 1] = entry
    return entry
end

function Capture.RebuildRecentView(db, limit)
    db = db or Capture.GetDatabase()
    limit = limit or Capture.RECENT_VIEW_LIMIT
    local entries = db.entries
    for i = #recentEntries, 1, -1 do
        recentEntries[i] = nil
    end
    if type(entries) ~= "table" then
        return recentEntries
    end
    local startIndex = #entries - limit + 1
    if startIndex < 1 then
        startIndex = 1
    end
    for i = startIndex, #entries do
        recentEntries[#recentEntries + 1] = entries[i]
    end
    return recentEntries
end

function Capture.PushRecentEntry(entry, limit)
    if type(entry) ~= "table" then
        return recentEntries
    end
    limit = limit or Capture.RECENT_VIEW_LIMIT
    recentEntries[#recentEntries + 1] = entry
    while #recentEntries > limit do
        table.remove(recentEntries, 1)
    end
    return recentEntries
end

function Capture.GetRecentView()
    return recentEntries
end

function Capture.ResolveLibraries(libStub)
    libStub = libStub or _G.LibStub
    local libs = {
        AceComm = nil,
        LibDeflate = nil,
        AceSerializer = nil,
    }
    if type(libStub) ~= "function" and type(libStub) ~= "table" then
        return libs
    end

    local function Get(name)
        local ok, lib = pcall(libStub, name, true)
        if ok then
            return lib
        end
        return nil
    end

    libs.AceComm = Get("AceComm-3.0")
    libs.LibDeflate = Get("LibDeflate")
    libs.AceSerializer = Get("AceSerializer-3.0")
    return libs
end

function Capture.AreDecodersAvailable(libs)
    libs = libs or Capture.ResolveLibraries()
    return libs.LibDeflate ~= nil and libs.AceSerializer ~= nil
end

-- Mirror current RCLootCouncil2 Services/Comms.lua ReceiveComm:
-- AceComm logical reassembly -> DecodeForWoWAddonChannel -> DecompressDeflate
-- -> AceSerializer Deserialize(command, data) -> optional xrealm unwrap.
function Capture.DecodeLogicalPayload(raw, libs, localPlayerName)
    local result = {
        decodeStatus = "unavailable",
        decodeError = nil,
        wireCommand = nil,
        decodedData = nil,
        effectiveCommand = nil,
        effectiveTarget = nil,
        effectiveData = nil,
    }

    if type(raw) ~= "string" then
        result.decodeStatus = "error"
        result.decodeError = "raw payload is not a string"
        return result
    end

    libs = libs or Capture.ResolveLibraries()
    local ld = libs.LibDeflate
    local serializer = libs.AceSerializer
    if not (ld and serializer and ld.DecodeForWoWAddonChannel and ld.DecompressDeflate and serializer.Deserialize) then
        result.decodeStatus = "unavailable"
        result.decodeError = "LibDeflate or AceSerializer-3.0 is not available"
        return result
    end

    local ok, decoded, decompressed, test, command, data = pcall(function()
        local decodedBytes = ld:DecodeForWoWAddonChannel(raw)
        local inflated = ld:DecompressDeflate(decodedBytes)
        local success, cmd, payload = serializer:Deserialize(inflated or "")
        return decodedBytes, inflated, success, cmd, payload
    end)

    if not ok then
        result.decodeStatus = "error"
        result.decodeError = tostring(decoded)
        return result
    end

    if decoded == nil then
        result.decodeStatus = "error"
        result.decodeError = "LibDeflate DecodeForWoWAddonChannel returned nil"
        return result
    end
    if decompressed == nil then
        result.decodeStatus = "error"
        result.decodeError = "LibDeflate DecompressDeflate returned nil"
        return result
    end
    if test ~= true then
        result.decodeStatus = "error"
        result.decodeError = tostring(command or "AceSerializer deserialization failed")
        return result
    end

    result.decodeStatus = "ok"
    result.wireCommand = command
    result.decodedData = Capture.NormalizeForSavedVariables(data)
    result.effectiveCommand = command
    result.effectiveData = result.decodedData

    if command == "xrealm" and type(data) == "table" then
        local target = data[1]
        local innerCommand = data[2]
        result.effectiveTarget = type(target) == "string" and target or Capture.NormalizeForSavedVariables(target)
        if type(innerCommand) == "string" then
            result.effectiveCommand = innerCommand
        else
            result.effectiveCommand = Capture.NormalizeForSavedVariables(innerCommand)
        end
        local rest = {}
        for i = 3, #data do
            rest[#rest + 1] = data[i]
        end
        result.effectiveData = Capture.NormalizeForSavedVariables(rest)
        if localPlayerName ~= nil and type(target) == "string" and target ~= localPlayerName then
            result.xrealmForLocalPlayer = false
        else
            result.xrealmForLocalPlayer = localPlayerName == nil or target == localPlayerName
        end
    end

    return result
end

function Capture.IsListenerRegistered()
    return commReceiver._registered == true
end

function Capture.GetRegisterCounts()
    local counts = {}
    for prefix, count in pairs(commReceiver._prefixRegisterCounts) do
        counts[prefix] = count
    end
    return counts, commReceiver._registerCount
end

function Capture.RegisterListener(aceComm)
    if commReceiver._registered then
        return false
    end

    aceComm = aceComm or Capture.ResolveLibraries().AceComm
    if not aceComm or not aceComm.Embed then
        return false, "AceComm-3.0 is not available"
    end

    if not commReceiver._embedded then
        aceComm:Embed(commReceiver)
        commReceiver._embedded = true
    end

    for i = 1, #Capture.RC_PREFIXES do
        local prefix = Capture.RC_PREFIXES[i]
        commReceiver:RegisterComm(prefix, "OnCommReceived")
        commReceiver._prefixRegisterCounts[prefix] = (commReceiver._prefixRegisterCounts[prefix] or 0) + 1
    end
    commReceiver._registerCount = commReceiver._registerCount + 1
    commReceiver._registered = true
    return true
end

function Capture.UnregisterListener()
    if not commReceiver._registered then
        return false
    end
    if commReceiver.UnregisterAllComm then
        commReceiver:UnregisterAllComm()
    end
    commReceiver._registered = false
    return true
end

function commReceiver.OnCommReceived(_self, prefix, message, distribution, sender)
    if not commReceiver._registered then
        return
    end
    Capture.HandleIncomingMessage(prefix, message, distribution, sender)
end

function Capture.BuildMessageEntry(prefix, message, distribution, sender, libs)
    local context = Capture.GetSessionContext()
    local raw = type(message) == "string" and message or tostring(message or "")
    local decoded = Capture.DecodeLogicalPayload(raw, libs, Capture.GetLocalPlayerId())

    return {
        kind = "message",
        timestamp = Capture.Now(),
        relativeTime = Capture.GetRelativeTime(),
        sessionId = context.sessionId,
        profileId = context.profileId,
        coordinator = context.coordinator,
        localPlayer = Capture.GetLocalPlayerId(),
        direction = "received",
        prefix = prefix,
        distribution = distribution,
        sender = sender,
        raw = raw,
        rawByteLength = #raw,
        decodeStatus = decoded.decodeStatus,
        decodeError = decoded.decodeError,
        wireCommand = decoded.wireCommand,
        decodedData = decoded.decodedData,
        effectiveCommand = decoded.effectiveCommand,
        effectiveTarget = decoded.effectiveTarget,
        effectiveData = decoded.effectiveData,
        xrealmForLocalPlayer = decoded.xrealmForLocalPlayer,
    }
end

function Capture.BuildMarkerEntry(kind, reason)
    local context = Capture.GetSessionContext()
    local libs = Capture.ResolveLibraries()
    return {
        kind = kind,
        timestamp = Capture.Now(),
        relativeTime = Capture.GetRelativeTime(),
        sessionId = context.sessionId,
        profileId = context.profileId,
        coordinator = context.coordinator,
        localPlayer = Capture.GetLocalPlayerId(),
        reason = reason,
        spectrumVersion = Capture.GetAddonVersion(Capture.PARENT_ADDON_NAME),
        childVersion = Capture.GetAddonVersion(Capture.ADDON_NAME),
        prefixes = Capture.CopyPrefixList(),
        decoderAvailable = Capture.AreDecodersAvailable(libs),
        aceCommAvailable = libs.AceComm ~= nil,
    }
end

function Capture.PersistEntry(entry)
    local db = Capture.GetDatabase()
    local stored = Capture.AppendEntry(db, entry)
    Capture.PushRecentEntry(stored)
    Capture.MarkViewDirty()
    return stored
end

function Capture.HandleIncomingMessage(prefix, message, distribution, sender)
    if not commReceiver._registered then
        return nil
    end
    if not Capture.IsKnownPrefix(prefix) then
        return nil
    end

    local entry = Capture.BuildMessageEntry(prefix, message, distribution, sender)
    return Capture.PersistEntry(entry)
end

function Capture.ReconcileListener(reason)
    local sessionActive = Capture.IsSpectrumSessionActive()
    if sessionActive then
        if commReceiver._registered and captureActive then
            return "already_active"
        end
        local registered = Capture.RegisterListener()
        if not captureActive then
            captureActive = true
            Capture.PersistEntry(Capture.BuildMarkerEntry("capture_start", reason or "session_active"))
        elseif registered then
            DebugInfo("RC listener re-registered without a new start marker (reason=%s)", tostring(reason))
        end
        return "started"
    end

    if not commReceiver._registered and not captureActive then
        return "already_inactive"
    end

    Capture.UnregisterListener()
    if captureActive then
        captureActive = false
        Capture.PersistEntry(Capture.BuildMarkerEntry("capture_stop", reason or "session_inactive"))
    end
    return "stopped"
end

local SESSION_HOOKS = {
    "StartSession",
    "EndSession",
    "_ResetSessionState",
    "TryRestorePersistedSession",
    "HandleSessionStart",
    "HandleSessionReannounce",
    "TakeoverSession",
    "Enable",
    "Disable",
}

function Capture.InstallSessionHooks()
    if hooksInstalled then
        return false
    end

    local SF = ParentAddon()
    local sync = SF and SF.LootHelperSync
    if not sync then
        return false
    end
    if type(hooksecurefunc) ~= "function" then
        return false
    end

    for i = 1, #SESSION_HOOKS do
        local methodName = SESSION_HOOKS[i]
        if type(sync[methodName]) == "function" then
            hooksecurefunc(sync, methodName, function()
                Capture.ReconcileListener(methodName)
            end)
        end
    end

    hooksInstalled = true
    return true
end

function Capture.AreHooksInstalled()
    return hooksInstalled
end

function Capture.FormatTimestamp(timestamp)
    if type(timestamp) ~= "number" then
        return "?"
    end
    local SF = ParentAddon()
    if SF and SF.FormatTimestampForUser then
        local ok, text = pcall(SF.FormatTimestampForUser, SF, timestamp)
        if ok and type(text) == "string" then
            return text
        end
    end
    if date then
        return date("%Y-%m-%d %H:%M:%S", timestamp)
    end
    return tostring(timestamp)
end

local function SummarizeValue(value)
    local valueType = type(value)
    if valueType == "nil" then
        return "-"
    end
    if valueType == "string" then
        local text = value:gsub("\r", "\\r"):gsub("\n", "\\n")
        if #text > 80 then
            text = text:sub(1, 80) .. "..."
        end
        return text
    end
    if valueType == "table" then
        local count = 0
        for _ in pairs(value) do
            count = count + 1
        end
        return string.format("{%d keys}", count)
    end
    return tostring(value)
end

function Capture.FormatEntryLine(entry)
    if type(entry) ~= "table" then
        return ""
    end
    local sequence = tostring(entry.sequence or "?")
    local timeText = Capture.FormatTimestamp(entry.timestamp)
    if entry.kind == "capture_start" or entry.kind == "capture_stop" then
        return string.format(
            "#%s %s [%s] session=%s reason=%s decoders=%s",
            sequence,
            timeText,
            entry.kind,
            tostring(entry.sessionId or "-"),
            tostring(entry.reason or "-"),
            entry.decoderAvailable and "yes" or "no"
        )
    end

    local command = entry.effectiveCommand or entry.wireCommand or "-"
    local summary = SummarizeValue(entry.effectiveData or entry.decodedData)
    return string.format(
        "#%s %s [%s] %s prefix=%s sender=%s cmd=%s decode=%s %s",
        sequence,
        timeText,
        entry.kind or "message",
        tostring(entry.direction or "received"),
        tostring(entry.prefix or "-"),
        tostring(entry.sender or "-"),
        tostring(command),
        tostring(entry.decodeStatus or "-"),
        summary
    )
end

function Capture.FormatLogText(entries)
    if type(entries) ~= "table" or #entries == 0 then
        return "No RC Loot Council communications captured yet.\n\nStart a Spectrum Loot Helper session, then generate RC Loot Council traffic."
    end
    local lines = {}
    for i = 1, #entries do
        lines[#lines + 1] = Capture.FormatEntryLine(entries[i])
    end
    return table.concat(lines, "\n")
end

function Capture.GetVisibleEntries()
    if showFullHistory then
        local db = Capture.GetDatabase()
        return db.entries or {}
    end
    return recentEntries
end

function Capture.SetShowFullHistory(enabled)
    showFullHistory = enabled and true or false
    uiDirty = true
end

function Capture.IsShowingFullHistory()
    return showFullHistory == true
end

function Capture.IsSettingsPageVisible()
    if not settingsPanel then
        return false
    end
    if settingsPanel.IsShown and not settingsPanel:IsShown() then
        return false
    end
    local SF = ParentAddon()
    local window = SF and SF.SettingsWindow
    if window and window.currentPageId and window.currentPageId ~= Capture.PAGE_ID then
        if window.frame and window.frame.IsShown and window.frame:IsShown() then
            return false
        end
    end
    return true
end

function Capture.MarkViewDirty()
    uiDirty = true
    if not Capture.IsSettingsPageVisible() then
        return
    end
    Capture.ScheduleVisibleRefresh()
end

function Capture.ScheduleVisibleRefresh()
    if uiRefreshPending then
        return
    end
    uiRefreshPending = true
    local function Flush()
        uiRefreshPending = false
        if uiDirty and Capture.IsSettingsPageVisible() then
            Capture.RefreshSettingsPage()
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, Flush)
    else
        Flush()
    end
end

function Capture.RefreshSettingsPage()
    if not settingsPanel then
        return
    end
    uiDirty = false
    local SF = ParentAddon()
    if SF and SF.SettingsUI and SF.SettingsUI.DefinitionRenderer then
        SF.SettingsUI.DefinitionRenderer:Refresh(settingsPanel)
    elseif settingsPanel.__sfPageBuilder and settingsPanel.__sfPageBuilder.Refresh then
        settingsPanel.__sfPageBuilder:Refresh()
    end
end

function Capture.GetStatusLines()
    local context = Capture.GetSessionContext()
    local libs = Capture.ResolveLibraries()
    local total, messages = Capture.CountEntries()
    local latest = Capture.GetLatestTimestamp()
    local latestText = latest and Capture.FormatTimestamp(latest) or "none"
    return {
        temporary = "Temporary diagnostic tooling. It does not award loot, write Loot Logs, or talk to RC Loot Council.",
        sessionActive = context.sessionActive and "Active" or "Inactive",
        listenerActive = commReceiver._registered and "Active" or "Inactive",
        prefixes = table.concat(Capture.RC_PREFIXES, ", "),
        decoderAvailable = Capture.AreDecodersAvailable(libs) and "Available" or "Unavailable",
        aceCommAvailable = libs.AceComm and "Available" or "Unavailable",
        sessionId = context.sessionId or "none",
        profileId = context.profileId or "none",
        coordinator = context.coordinator or "none",
        messageCount = tostring(messages),
        entryCount = tostring(total),
        latestTimestamp = latestText,
        savedVariablesGlobal = Capture.SAVED_VARIABLES_GLOBAL,
        savedVariablesFile = Capture.GetSavedVariablesFileHint(),
        reloadReminder = "WoW writes this SavedVariables file on /reload or logout. The in-memory table is already the authoritative log.",
        receiveOnly = "Receive-only: this logger records logical AceComm messages delivered to this client. Locally sent RC traffic is not echoed by WoW, so outbound messages are not captured.",
    }
end

function Capture.RegisterSettingsPage()
    if pageRegistered then
        return false
    end
    local SF = ParentAddon()
    if not (SF and SF.SettingsUI and SF.SettingsUI.RegisterPage) then
        return false
    end

    local Page = {
        id = Capture.PAGE_ID,
        parentId = "lootHelper",
        name = "RC Loot Council",
        navLabel = "RC Loot Council",
        description = "Temporary diagnostic capture of RC Loot Council communications.",
        order = 24,
    }

    function Page.Build(_self, panel)
        settingsPanel = panel
        local renderer = SF.SettingsUI.DefinitionRenderer
        if not renderer then
            return
        end

        local function Status(label, key)
            return {
                type = "display",
                label = label,
                get = function()
                    return Capture.GetStatusLines()[key]
                end,
            }
        end

        renderer:Build(panel, {
            sections = {
                {
                    id = "about",
                    title = "Temporary Diagnostic Capture",
                    intro = "This page is temporary diagnostic tooling. It records RC Loot Council addon communications while a Spectrum Loot Helper session is active. It does not interpret those messages into Spectrum loot actions. An empty Optional sidebar row may also appear for this child addon; this Loot Helper tab is the live log.",
                    items = {
                        { type = "help", text = Capture.GetStatusLines().receiveOnly, indent = "label" },
                        { type = "help", text = Capture.GetStatusLines().reloadReminder, indent = "label" },
                    },
                },
                {
                    id = "status",
                    title = "Capture Status",
                    items = {
                        Status("Spectrum session", "sessionActive"),
                        Status("RC listener", "listenerActive"),
                        Status("RC prefixes", "prefixes"),
                        Status("Semantic decoder", "decoderAvailable"),
                        Status("AceComm", "aceCommAvailable"),
                        Status("Spectrum session ID", "sessionId"),
                        Status("Active profile ID", "profileId"),
                        Status("Coordinator", "coordinator"),
                        Status("Persisted RC messages", "messageCount"),
                        Status("Persisted entries", "entryCount"),
                        Status("Most recent capture", "latestTimestamp"),
                        Status("SavedVariables global", "savedVariablesGlobal"),
                        Status("Expected SavedVariables file", "savedVariablesFile"),
                    },
                },
                {
                    id = "log",
                    title = "Captured Communications",
                    items = {
                        { type = "help", text = "Live view shows the most recent 250 persisted entries. Use the button below to load the full unbounded history into this view. There is no clear/reset action.", indent = "label" },
                        {
                            type = "button",
                            label = "History View",
                            buttonText = function()
                                if Capture.IsShowingFullHistory() then
                                    return "Show Recent 250"
                                end
                                return "Load Full History"
                            end,
                            width = 160,
                            onClick = function(ctx)
                                Capture.SetShowFullHistory(not Capture.IsShowingFullHistory())
                                if ctx.pageBuilder and ctx.pageBuilder.Refresh then
                                    ctx.pageBuilder:Refresh()
                                end
                            end,
                        },
                        {
                            type = "scrollableText",
                            label = "",
                            height = 320,
                            get = function()
                                return Capture.FormatLogText(Capture.GetVisibleEntries())
                            end,
                        },
                    },
                },
            },
        })
    end

    function Page.Refresh(_self, panel)
        settingsPanel = panel
        uiDirty = false
        if SF.SettingsUI.DefinitionRenderer then
            SF.SettingsUI.DefinitionRenderer:Refresh(panel)
        end
    end

    SF.SettingsUI:RegisterPage(Page)
    pageRegistered = true
    return true
end

function Capture.Init(reason)
    if initialized then
        Capture.ReconcileListener(reason or "Init(reenter)")
        return false
    end
    initialized = true

    local db = Capture.GetDatabase()
    Capture.RebuildRecentView(db)
    Capture.RegisterSettingsPage()
    Capture.InstallSessionHooks()
    Capture.ReconcileListener(reason or "Init")
    DebugInfo("RC Loot Council capture initialized (entries=%d)", #db.entries)
    return true
end

local eventFrame = nil

local function EnsureEventFrame()
    if eventFrame or not CreateFrame then
        return eventFrame
    end
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("PLAYER_LOGIN")
    eventFrame:SetScript("OnEvent", function(_, event, loadedName)
        if event == "ADDON_LOADED" then
            if loadedName == Capture.ADDON_NAME then
                Capture.Init("ADDON_LOADED")
            elseif loadedName == "RCLootCouncil" or loadedName == "RCLootCouncil2" then
                -- Decoder libraries may become available after RC loads. Do not
                -- start listening here; session reconcile remains the only gate.
                uiDirty = true
                if Capture.IsSettingsPageVisible() then
                    Capture.ScheduleVisibleRefresh()
                end
            end
        elseif event == "PLAYER_LOGIN" then
            Capture.InstallSessionHooks()
            Capture.RegisterSettingsPage()
            Capture.ReconcileListener("PLAYER_LOGIN")
        end
    end)
    return eventFrame
end

EnsureEventFrame()

if ns ~= _G then
    ns.RCLootCouncilCapture = Capture
end
