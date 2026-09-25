-- Permanent optional child addon.
-- Records finalized RC Loot Council awards into Spectrum Loot Logs while a
-- Spectrum Loot Helper session is active, and warns when a BiS-qualified
-- response conflicts with an already-consumed opportunity.
-- No SavedVariables and no raw traffic persistence.

local addonName, ns = ...

ns = ns or {}
ns.RCLootCouncilIntegration = ns.RCLootCouncilIntegration or {}
local Integration = ns.RCLootCouncilIntegration

Integration.ADDON_NAME = addonName or "SpectrumFederation_RCLootCouncilIntegration"
Integration.PARENT_ADDON_NAME = "SpectrumFederation"
Integration.PAGE_ID = "lootHelperRCLootCouncil"
Integration.RC_PREFIX = "RCLC"
Integration.DEBUG_CATEGORY = "RCLC_INTEGRATION"
-- AceComm delivers the reassembled payload. Bound it before inflate so a
-- RAID/GUILD sender cannot stall the UI thread with a compression bomb.
Integration.MAX_COMPRESSED_BYTES = 8192
Integration.MAX_DECOMPRESSED_BYTES = 32768
Integration.MAX_HISTORY_DATA_FIELDS = 16

local initialized = false
local pageRegistered = false
local hooksInstalled = false
local settingsPanel = nil
local seenAwardKeys = {}
local warnedAwardKeys = {}
local responseWarningKeys = {}
local awardPopupKeys = {}
local POPUP_KEY = "SF_RCLC_BIS_CONFLICT_INFO"

local commReceiver = {
    _registered = false,
    _embedded = false,
}

local messageReceiver = {
    _registered = false,
    _embedded = false,
    _fallbackOnRC = false,
}

local SESSION_HOOKS = {
    "StartSession",
    "EndSession",
    "_ResetSessionState",
    "TryRestorePersistedSession",
    "HandleSessionStart",
    "HandleSessionReannounce",
    "HandleSessionHeartbeat",
    "TakeoverSession",
    "Enable",
    "Disable",
}

local function ParentAddon()
    return _G[Integration.PARENT_ADDON_NAME]
end

local function DebugInfo(message, ...)
    local SF = ParentAddon()
    if SF and SF.Debug then
        SF.Debug:Info(Integration.DEBUG_CATEGORY, message, ...)
    end
end

local function DebugWarn(message, ...)
    local SF = ParentAddon()
    if SF and SF.Debug then
        SF.Debug:Warn(Integration.DEBUG_CATEGORY, message, ...)
    end
end

local function GetLocalPlayerId()
    local SF = ParentAddon()
    if SF and SF.GetPlayerFullIdentifier then
        local ok, value = pcall(SF.GetPlayerFullIdentifier, SF)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    if SF and SF.LootLog and SF.LootLog.NormalizePlayerId then
        local name = UnitName and UnitName("player")
        return SF.LootLog.NormalizePlayerId(name)
    end
    return nil
end

function Integration.IsSpectrumSessionActive()
    local SF = ParentAddon()
    local sync = SF and SF.LootHelperSync
    if not (sync and sync.IsSessionActive) then
        return false
    end
    local ok, active = pcall(sync.IsSessionActive, sync)
    return ok and active == true
end

function Integration.GetSelectedProfile()
    local SF = ParentAddon()
    if SF and SF.GetActiveProfile then
        local ok, profile = pcall(SF.GetActiveProfile, SF)
        if ok then
            return profile
        end
    end
    return SF and SF.lootHelperDB and SF.lootHelperDB.activeProfile or nil
end

-- UI-selected profile. Not the authority for live RC award processing.
function Integration.GetActiveProfile()
    return Integration.GetSelectedProfile()
end

-- Profile attached to the active Spectrum Loot Helper session.
-- Never falls back to the locally selected profile.
function Integration.GetSessionProfile()
    if not Integration.IsSpectrumSessionActive() then
        return nil, "no_session"
    end
    local SF = ParentAddon()
    local sync = SF and SF.LootHelperSync
    if not sync then
        DebugWarn("Active Spectrum session has no LootHelperSync")
        return nil, "no_profile"
    end

    local profileId
    if type(sync.GetSessionProfileId) == "function" then
        local ok, value = pcall(sync.GetSessionProfileId, sync)
        if ok and type(value) == "string" and value ~= "" then
            profileId = value
        end
    elseif sync.state and type(sync.state.profileId) == "string" and sync.state.profileId ~= "" then
        profileId = sync.state.profileId
    end
    if type(profileId) ~= "string" or profileId == "" then
        DebugWarn("Active Spectrum session has no profileId")
        return nil, "no_profile"
    end

    local profile
    if type(sync.FindLocalProfileById) == "function" then
        local ok, found = pcall(sync.FindLocalProfileById, sync, profileId)
        if ok then
            profile = found
        end
    end
    if not (profile and profile.TryAddRCLootCouncilAward) then
        DebugWarn("Session profile %s is not available locally", tostring(profileId))
        return nil, "no_profile"
    end
    return profile
end

-- Settings edit the session profile while a session is live; otherwise the
-- selected Loot Helper profile, matching existing Settings conventions.
function Integration.GetSettingsProfile()
    if Integration.IsSpectrumSessionActive() then
        local profile = Integration.GetSessionProfile()
        return profile
    end
    return Integration.GetSelectedProfile()
end

local function WipeTable(t)
    if type(wipe) == "function" then
        wipe(t)
        return
    end
    for key in pairs(t) do
        t[key] = nil
    end
end

function Integration.ClearBisProtectionMemory()
    WipeTable(responseWarningKeys)
    WipeTable(awardPopupKeys)
end

function Integration.ClearSessionMemory()
    WipeTable(seenAwardKeys)
    WipeTable(warnedAwardKeys)
    Integration.ClearBisProtectionMemory()
end

function Integration.ResolveLibraries(libStub)
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

function Integration.NormalizeRCPlayerId(player)
    if type(player) == "table" then
        local name
        if type(player.GetName) == "function" then
            name = player:GetName()
        elseif type(player.GetFullName) == "function" then
            name = player:GetFullName()
        else
            name = player.name
        end
        player = name
    end
    local SF = ParentAddon()
    if SF and SF.LootLog and SF.LootLog.NormalizePlayerId then
        return SF.LootLog.NormalizePlayerId(player)
    end
    if type(player) == "string" and player ~= "" then
        return player
    end
    return nil
end

function Integration.SamePlayer(a, b)
    local SF = ParentAddon()
    if SF and SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b) == true
    end
    local left = Integration.NormalizeRCPlayerId(a)
    local right = Integration.NormalizeRCPlayerId(b)
    return left and right and string.lower(left) == string.lower(right)
end

function Integration.GetCurrentRCMasterLooter()
    local rc = _G.RCLootCouncil
    if type(rc) ~= "table" then
        return nil
    end

    -- Prefer the live ML RC already resolved for this client/session.
    local cached = Integration.NormalizeRCPlayerId(rc.masterLooter)
    if cached then
        return cached
    end

    -- Public API: GetML() -> isLocalML, ml (Player or name).
    if type(rc.GetML) == "function" then
        local ok, first, second = pcall(rc.GetML, rc)
        if ok then
            local ml = second
            if ml == nil and first ~= nil and first ~= true and first ~= false then
                ml = first
            end
            local normalized = Integration.NormalizeRCPlayerId(ml)
            if normalized then
                return normalized
            end
        end
    end
    return nil
end

function Integration.SenderIsCurrentMasterLooter(sender)
    if type(sender) ~= "string" or sender == "" then
        return false
    end
    -- Compare the AceComm sender to the resolved current ML only.
    -- Do not call RCLootCouncil:IsMasterLooter() as a fallback: some builds
    -- treat that as "is the local client ML" and ignore the unit argument.
    local current = Integration.GetCurrentRCMasterLooter()
    return current ~= nil and Integration.SamePlayer(sender, current)
end

-- Decode RC MAIN prefix traffic enough to recover ("history", winner, historyTable).
-- Mirrors current RCLootCouncil2 Services/Comms.lua: Serialize(command, data)
-- where data is the argument table, and xrealm is command="xrealm",
-- data = { target, innerCommand, ...innerArgs }.
function Integration.DecodeHistoryPayload(raw, libs, opts)
    local result = {
        ok = false,
        command = nil,
        winner = nil,
        history = nil,
    }
    if type(raw) ~= "string" or raw == "" then
        return result
    end
    if #raw > Integration.MAX_COMPRESSED_BYTES then
        return result
    end

    opts = type(opts) == "table" and opts or {}
    libs = libs or Integration.ResolveLibraries()
    local ld = libs.LibDeflate
    local serializer = libs.AceSerializer
    if not (ld and serializer and ld.DecodeForWoWAddonChannel and ld.DecompressDeflate and serializer.Deserialize) then
        return result
    end

    local ok, unpacked = pcall(function()
        local decodedBytes = ld:DecodeForWoWAddonChannel(raw)
        if type(decodedBytes) ~= "string" or #decodedBytes > Integration.MAX_COMPRESSED_BYTES then
            return { false }
        end
        -- LibDeflate's public DecompressDeflate has no max-output argument.
        -- Reject after inflate so we never deserialize a bomb. Callers must
        -- authenticate the sender before this runs. The compressed and
        -- decompressed size caps bound the work that remains.
        local inflated = ld:DecompressDeflate(decodedBytes)
        if type(inflated) ~= "string" or #inflated > Integration.MAX_DECOMPRESSED_BYTES then
            return { false }
        end
        return { serializer:Deserialize(inflated) }
    end)
    if not ok or type(unpacked) ~= "table" or unpacked[1] ~= true then
        return result
    end

    -- RCLootCouncil2 Comms.EncodeData serializes exactly (command, dataTable).
    -- Deserialize therefore returns true, command, data — never a flattened
    -- vararg list of command arguments.
    local command = unpacked[2]
    local data = unpacked[3]
    if type(data) ~= "table" then
        result.command = command
        return result
    end
    if #data > Integration.MAX_HISTORY_DATA_FIELDS then
        result.command = command
        return result
    end

    if command == "xrealm" then
        -- ReceiveComm: target = tremove(data, 1); if target is local player then
        -- command = tremove(data, 1); remaining data is the original args table.
        local target = data[1]
        local localPlayer = opts.localPlayer or GetLocalPlayerId()
        if not Integration.SamePlayer(target, localPlayer) then
            result.command = "xrealm"
            return result
        end
        command = data[2]
        local inner = {}
        for i = 3, #data do
            inner[#inner + 1] = data[i]
        end
        data = inner
    end

    result.command = command
    result.data = data
    result.winner = data[1]
    result.history = data[2]
    if command == "history" and type(result.winner) == "string" and type(result.history) == "table" then
        result.ok = true
    end
    return result
end

function Integration.DecodeRCPayload(raw, libs, opts)
    return Integration.DecodeHistoryPayload(raw, libs, opts)
end

function Integration.MarkSeen(awardKey)
    if type(awardKey) == "string" and awardKey ~= "" then
        seenAwardKeys[awardKey] = true
    end
end

function Integration.WasSeen(awardKey)
    return type(awardKey) == "string" and seenAwardKeys[awardKey] == true
end

local function IsEffectiveAdmin(profile)
    local SF = ParentAddon()
    local Imp = SF and SF.LootHelperImpersonation
    if Imp and Imp.IsEffectiveLocalAdmin then
        return Imp:IsEffectiveLocalAdmin(profile)
    end
    return profile and profile.IsCurrentUserAdmin and profile:IsCurrentUserAdmin()
end

function Integration.WarnNonMember(canonical, profile)
    if type(canonical) ~= "table" then
        return false
    end
    local awardKey = canonical.awardKey
    if Integration.WasSeen(awardKey) or (type(awardKey) == "string" and warnedAwardKeys[awardKey]) then
        return false
    end
    if type(awardKey) == "string" then
        warnedAwardKeys[awardKey] = true
    end

    local SF = ParentAddon()
    if not profile then
        profile = Integration.GetSessionProfile()
    end
    if not IsEffectiveAdmin(profile) then
        return false
    end
    local message = string.format(
        "%s was awarded to %s, who is not a member of the active profile. No Loot Log was recorded.",
        tostring(canonical.itemLink or "[item]"),
        tostring(canonical.winner or "Unknown")
    )
    if SF and SF.PrintWarning then
        SF:PrintWarning(message)
        return true
    end
    return false
end

function Integration.ProcessBonusRoll(canonical, source)
    if type(canonical) ~= "table" then
        return "invalid"
    end
    if not Integration.IsSpectrumSessionActive() then
        return "no_session"
    end
    if Integration.WasSeen(canonical.awardKey) then
        return "seen"
    end

    local profile, profileErr = Integration.GetSessionProfile()
    if not profile then
        return profileErr or "no_profile"
    end

    local member = profile.getMemberByID and profile:getMemberByID(canonical.winner)
    if not member then
        Integration.WarnNonMember(canonical, profile)
        Integration.MarkSeen(canonical.awardKey)
        return "not_member"
    end

    local ok, err = profile.TryAddBonusRoll and profile:TryAddBonusRoll(canonical)
    Integration.MarkSeen(canonical.awardKey)
    if ok then
        DebugInfo("Recorded bonus roll %s from %s", tostring(canonical.awardKey), tostring(source))
        return "recorded"
    end
    DebugInfo("Skipped bonus roll %s from %s (%s)", tostring(canonical.awardKey), tostring(source), tostring(err))
    return err or "skipped"
end

function Integration.ProcessCanonicalAward(canonical, source)
    if type(canonical) ~= "table" then
        return "invalid"
    end
    if not Integration.IsSpectrumSessionActive() then
        return "no_session"
    end
    if Integration.WasSeen(canonical.awardKey) then
        return "seen"
    end

    local profile, profileErr = Integration.GetSessionProfile()
    if not profile then
        return profileErr or "no_profile"
    end

    local member = profile.getMemberByID and profile:getMemberByID(canonical.winner)
    if not member then
        Integration.WarnNonMember(canonical, profile)
        Integration.MarkSeen(canonical.awardKey)
        return "not_member"
    end

    local ok, err = profile:TryAddRCLootCouncilAward(canonical)
    Integration.MarkSeen(canonical.awardKey)
    if ok then
        DebugInfo("Recorded RC award %s from %s", tostring(canonical.awardKey), tostring(source))
        return "recorded"
    end
    DebugInfo("Skipped RC award %s from %s (%s)", tostring(canonical.awardKey), tostring(source), tostring(err))
    return err or "skipped"
end

function Integration.HandleHistory(awarder, winner, history, source)
    if not Integration.IsSpectrumSessionActive() then
        return "no_session"
    end
    local SF = ParentAddon()
    if not (SF and SF.LootLog and SF.LootLog.BuildRCLootCouncilCanonical) then
        return "unavailable"
    end
    if SF.LootLog.IsBonusRollHistory and SF.LootLog.IsBonusRollHistory(history) then
        if not SF.LootLog.BuildBonusRollCanonical then
            return "unavailable"
        end
        local bonus = SF.LootLog.BuildBonusRollCanonical(awarder, winner, history)
        if not bonus then
            return "invalid"
        end
        return Integration.ProcessBonusRoll(bonus, source or "history")
    end
    local canonical = SF.LootLog.BuildRCLootCouncilCanonical(awarder, winner, history)
    if not canonical then
        return "invalid"
    end
    return Integration.ProcessCanonicalAward(canonical, source or "history")
end

local function ItemStringFromLink(itemLink)
    local SF = ParentAddon()
    if SF and SF.LootLog and SF.LootLog.ExtractItemString then
        local extracted = SF.LootLog.ExtractItemString(itemLink)
        if type(extracted) == "string" and extracted ~= "" then
            return extracted
        end
    end
    return type(itemLink) == "string" and itemLink or ""
end

local function ResponseWarningKey(player, itemLink, responseId, typeCode, isAwardReason, responseText)
    return table.concat({
        tostring(player or ""),
        ItemStringFromLink(itemLink),
        tostring(responseId or ""),
        tostring(typeCode or ""),
        isAwardReason and "1" or "0",
        string.lower(type(responseText) == "string" and responseText or ""),
    }, "|")
end

local function AwardPopupKey(player, session, itemLink)
    return table.concat({
        tostring(player or ""),
        tostring(session or ""),
        ItemStringFromLink(itemLink),
    }, "|")
end

local function TextsMatch(left, right)
    if type(left) ~= "string" or type(right) ~= "string" then
        return false
    end
    local a = strtrim(left)
    local b = strtrim(right)
    if a == "" or b == "" then
        return false
    end
    return string.lower(a) == string.lower(b)
end

local function NumericResponseId(value)
    local number = tonumber(value)
    if not number or number < 1 or number ~= math.floor(number) then
        return nil
    end
    return number
end

function Integration.ResolveRCSession(session)
    local rc = _G.RCLootCouncil
    if type(rc) ~= "table" or type(rc.GetLootTable) ~= "function" then
        return nil, "no_loot_table"
    end
    local ok, lootTable = pcall(rc.GetLootTable, rc)
    if not ok or type(lootTable) ~= "table" then
        return nil, "no_loot_table"
    end
    session = tonumber(session)
    if not session or session < 1 or session ~= math.floor(session) then
        return nil, "bad_session"
    end
    local entry = lootTable[session]
    if type(entry) ~= "table" then
        return nil, "bad_session"
    end
    local link = entry.link
    if type(link) ~= "string" or link == "" then
        return nil, "no_item"
    end
    local typeCode = entry.typeCode
    if type(typeCode) ~= "string" or strtrim(typeCode) == "" then
        typeCode = "default"
    else
        typeCode = strtrim(typeCode)
    end
    return {
        session = session,
        itemLink = link,
        typeCode = typeCode,
        candidates = entry.candidates,
        entry = entry,
    }
end

local function CandidateRecord(candidates, player)
    if type(candidates) ~= "table" or not player then
        return nil
    end
    if type(candidates[player]) == "table" then
        return candidates[player]
    end
    for name, data in pairs(candidates) do
        if type(data) == "table" and Integration.SamePlayer(name, player) then
            return data
        end
    end
    return nil
end

local function PlayerIsKnownCandidate(sessionInfo, player)
    return CandidateRecord(sessionInfo and sessionInfo.candidates, player) ~= nil
end

local function RCResponseText(typeCode, responseId)
    local rc = _G.RCLootCouncil
    if type(rc) ~= "table" or type(rc.GetResponse) ~= "function" or responseId == nil then
        return nil
    end
    local ok, response = pcall(rc.GetResponse, rc, typeCode, responseId)
    if ok and type(response) == "table" and type(response.text) == "string" then
        local text = strtrim(response.text)
        if text ~= "" then
            return text
        end
    end
    return nil
end

local function MatchingAwardReason(responseText)
    if type(responseText) ~= "string" or strtrim(responseText) == "" then
        return nil
    end
    local rc = _G.RCLootCouncil
    local db = rc and ((type(rc.Getdb) == "function" and rc:Getdb()) or rc.db)
    local profile = db and (db.profile or db)
    local reasons = profile and profile.awardReasons
    if type(reasons) ~= "table" then
        return nil
    end
    for _, entry in ipairs(reasons) do
        if type(entry) == "table" and TextsMatch(entry.text or entry.label, responseText) then
            local responseId = Integration.AwardReasonHistoryResponseId(entry)
            if responseId ~= nil then
                return responseId, strtrim(entry.text or entry.label)
            end
        end
    end
    return nil
end

local function CandidateResponseId(record)
    if type(record) ~= "table" then
        return nil
    end
    local direct = NumericResponseId(record.response)
    if direct then
        return direct
    end
    return NumericResponseId(record.real_response)
end

function Integration.ShowInformationalPopup(message)
    if type(message) ~= "string" or message == "" then
        return false
    end
    if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then
        DebugInfo("BiS conflict popup skipped; StaticPopup is unavailable")
        return false
    end
    if not StaticPopupDialogs[POPUP_KEY] then
        StaticPopupDialogs[POPUP_KEY] = {
            text = "%s",
            button1 = _G.OKAY or "OK",
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    local shown = StaticPopup_Show(POPUP_KEY, message)
    return shown ~= nil
end

function Integration.LocalPlayerIsCurrentMasterLooter()
    local localId = GetLocalPlayerId()
    return localId ~= nil and Integration.SenderIsCurrentMasterLooter(localId)
end

-- Read-only. Selecting or changing a response never consumes BiS state.
function Integration.WarnBisResponseConflict(profile, opts)
    opts = type(opts) == "table" and opts or {}
    if not profile or type(profile.EvaluateRCBisConflict) ~= "function" then
        return "unavailable"
    end
    if not IsEffectiveAdmin(profile) then
        return "not_admin"
    end
    if not profile.IsLiveBisAutomationActive or not profile:IsLiveBisAutomationActive() then
        return "inactive"
    end
    local player = opts.player
    if type(player) ~= "string" or player == "" then
        return "unresolved"
    end
    -- Retransmits of a warning already shown must not rebuild BiS state.
    local key = ResponseWarningKey(
        player,
        opts.itemLink,
        opts.responseId,
        opts.typeCode,
        opts.isAwardReason and true or false,
        opts.response or ""
    )
    if responseWarningKeys[key] then
        return "duplicate"
    end
    local evaluation = profile:EvaluateRCBisConflict({
        memberId = player,
        itemLink = opts.itemLink,
        response = opts.response,
        responseId = opts.responseId,
        typeCode = opts.typeCode,
        isAwardReason = opts.isAwardReason,
    })
    if type(evaluation) ~= "table" then
        return "unavailable"
    end
    if not evaluation.qualified then
        return "not_bis"
    end
    if evaluation.uncertain or not evaluation.conflict then
        if evaluation.uncertain then
            DebugInfo(
                "Skipping double-BiS response warning for %s; opportunity state is unresolved",
                tostring(player)
            )
            return "unresolved"
        end
        return "clear"
    end
    local responseLabel = evaluation.responseLabel
    local slotLabel = evaluation.slotLabel
    if type(responseLabel) ~= "string" or responseLabel == "" or type(slotLabel) ~= "string" or slotLabel == "" then
        DebugInfo("Skipping double-BiS response warning for %s; label is unresolved", tostring(player))
        return "unresolved"
    end
    local SF = ParentAddon()
    local message = string.format(
        "%s selected %s for %s, but their BiS opportunity for %s has already been used.",
        player,
        responseLabel,
        tostring(opts.itemLink or "[item]"),
        slotLabel
    )
    if not (SF and SF.PrintWarning) then
        return "unavailable"
    end
    responseWarningKeys[key] = true
    SF:PrintWarning(message)
    DebugInfo("Warned admins about a conflicting BiS response from %s", player)
    return "warned"
end

local function ParseResponseData(data)
    if type(data) ~= "table" then
        return nil
    end
    local session = tonumber(data[1])
    if not session then
        return nil
    end
    if type(data[2]) == "table" then
        return {
            session = session,
            responder = nil,
            responseTable = data[2],
            forwarded = false,
        }
    end
    if type(data[2]) == "string" and type(data[3]) == "table" then
        return {
            session = session,
            responder = data[2],
            responseTable = data[3],
            forwarded = true,
        }
    end
    return nil
end

local function AcceptNamedResponder(player, sessionInfo, profile)
    if not player then
        return nil, "unresolved"
    end
    if not PlayerIsKnownCandidate(sessionInfo, player) then
        DebugInfo("Ignoring RC response from %s; responder is not a live candidate", tostring(player))
        return nil, "untrusted"
    end
    local member = profile and profile.getMemberByID and profile:getMemberByID(player) or nil
    if not member then
        DebugInfo("Skipping double-BiS response warning for unknown Spectrum member %s", tostring(player))
        return nil, "unresolved"
    end
    return player, nil
end

local function AcceptResponsePlayer(sender, parsed, sessionInfo, profile)
    local responder = parsed.forwarded and parsed.responder or sender
    local player = Integration.NormalizeRCPlayerId(responder)
    if not player then
        return nil, "unresolved"
    end
    if parsed.forwarded then
        if not Integration.SenderIsCurrentMasterLooter(sender) then
            return nil, "not_ml"
        end
    elseif not Integration.SamePlayer(sender, player) then
        return nil, "untrusted"
    end
    return AcceptNamedResponder(player, sessionInfo, profile)
end

local function QualifyResponseArgs(rawResponse, typeCode)
    local responseId = NumericResponseId(rawResponse)
    if responseId == nil then
        if type(rawResponse) ~= "string" or strtrim(rawResponse) == "" then
            return nil
        end
        return {
            response = strtrim(rawResponse),
            responseId = nil,
            typeCode = nil,
            isAwardReason = false,
        }
    end
    return {
        response = RCResponseText(typeCode, responseId),
        responseId = responseId,
        typeCode = typeCode,
        isAwardReason = false,
    }
end

function Integration.HandleCandidateResponse(sender, data)
    if not Integration.IsSpectrumSessionActive() then
        return "no_session"
    end
    local parsed = ParseResponseData(data)
    if not parsed or type(parsed.responseTable) ~= "table" then
        return "ignored"
    end
    local sessionInfo, sessionErr = Integration.ResolveRCSession(parsed.session)
    if not sessionInfo then
        DebugInfo("RC response session unresolved (%s)", tostring(sessionErr))
        return "unresolved"
    end
    local profile = Integration.GetSessionProfile()
    if not profile then
        return "no_profile"
    end
    local player, trustErr = AcceptResponsePlayer(sender, parsed, sessionInfo, profile)
    if not player then
        return trustErr or "untrusted"
    end
    local qualified = QualifyResponseArgs(parsed.responseTable.response, sessionInfo.typeCode)
    if not qualified then
        return "ignored"
    end
    return Integration.WarnBisResponseConflict(profile, {
        player = player,
        itemLink = sessionInfo.itemLink,
        session = sessionInfo.session,
        response = qualified.response,
        responseId = qualified.responseId,
        typeCode = qualified.typeCode,
        isAwardReason = qualified.isAwardReason,
    })
end

function Integration.HandleChangeResponse(sender, data)
    if not Integration.IsSpectrumSessionActive() then
        return "no_session"
    end
    if not Integration.SenderIsCurrentMasterLooter(sender) then
        DebugInfo("Ignoring RC change_response from non-ML sender %s", tostring(sender))
        return "not_ml"
    end
    if type(data) ~= "table" then
        return "ignored"
    end
    local session = tonumber(data[1])
    local name = data[2]
    local rawResponse = data[3]
    if not session or type(name) ~= "string" or rawResponse == nil then
        return "ignored"
    end
    local sessionInfo, sessionErr = Integration.ResolveRCSession(session)
    if not sessionInfo then
        DebugInfo("RC change_response session unresolved (%s)", tostring(sessionErr))
        return "unresolved"
    end
    local profile = Integration.GetSessionProfile()
    if not profile then
        return "no_profile"
    end
    local player, trustErr = AcceptNamedResponder(Integration.NormalizeRCPlayerId(name), sessionInfo, profile)
    if not player then
        return trustErr or "untrusted"
    end
    local qualified = QualifyResponseArgs(rawResponse, sessionInfo.typeCode)
    if not qualified then
        return "ignored"
    end
    return Integration.WarnBisResponseConflict(profile, {
        player = player,
        itemLink = sessionInfo.itemLink,
        session = sessionInfo.session,
        response = qualified.response,
        responseId = qualified.responseId,
        typeCode = qualified.typeCode,
        isAwardReason = qualified.isAwardReason,
    })
end

local function AwardKeyFromSessionHistory(sessionInfo, winner)
    local history = sessionInfo and sessionInfo.entry and sessionInfo.entry.history
    if type(history) ~= "table" then
        return nil
    end
    local SF = ParentAddon()
    if not (SF and SF.LootLog and SF.LootLog.BuildRCLootCouncilCanonical) then
        return nil
    end
    local awarder = Integration.GetCurrentRCMasterLooter() or GetLocalPlayerId()
    local canonical = SF.LootLog.BuildRCLootCouncilCanonical(awarder, winner, history)
    return canonical and canonical.awardKey or nil
end

local function ResolveAwardResponse(sessionInfo, winner, responseText)
    local record = CandidateRecord(sessionInfo and sessionInfo.candidates, winner)
    local responseId = CandidateResponseId(record)
    local typeCode = sessionInfo and sessionInfo.typeCode or "default"
    local buttonText = RCResponseText(typeCode, responseId)
    local textGiven = type(responseText) == "string" and strtrim(responseText) ~= ""
    if responseId and (not textGiven or TextsMatch(buttonText, responseText)) then
        return {
            response = buttonText or responseText,
            responseId = responseId,
            typeCode = typeCode,
            isAwardReason = false,
        }
    end
    if textGiven then
        local reasonId, reasonText = MatchingAwardReason(responseText)
        if reasonId then
            return {
                response = reasonText or responseText,
                responseId = reasonId,
                typeCode = nil,
                isAwardReason = true,
            }
        end
    end
    if responseId and buttonText == nil then
        return {
            response = textGiven and strtrim(responseText) or nil,
            responseId = responseId,
            typeCode = typeCode,
            isAwardReason = false,
        }
    end
    if textGiven then
        return {
            response = strtrim(responseText),
            responseId = nil,
            typeCode = nil,
            isAwardReason = false,
        }
    end
    return nil
end

function Integration.HandleAwardSuccess(session, winner, _status, itemLink, responseText)
    if not Integration.IsSpectrumSessionActive() then
        return "no_session"
    end
    if not Integration.LocalPlayerIsCurrentMasterLooter() then
        return "not_ml"
    end
    local sessionInfo, sessionErr = Integration.ResolveRCSession(session)
    if not sessionInfo then
        DebugInfo("RC award popup session unresolved (%s)", tostring(sessionErr))
        return "unresolved"
    end
    if type(itemLink) == "string" and itemLink ~= "" and ItemStringFromLink(itemLink) ~= ItemStringFromLink(sessionInfo.itemLink) then
        DebugInfo("RC award popup item does not match session %s", tostring(session))
        return "unresolved"
    end
    local profile = Integration.GetSessionProfile()
    if not profile or type(profile.EvaluateRCBisConflict) ~= "function" then
        return profile and "unavailable" or "no_profile"
    end
    if not profile.IsLiveBisAutomationActive or not profile:IsLiveBisAutomationActive() then
        return "inactive"
    end
    local player = Integration.NormalizeRCPlayerId(winner)
    if not player or not (profile.getMemberByID and profile:getMemberByID(player)) then
        DebugInfo("Skipping double-BiS award popup; winner is unresolved")
        return "unresolved"
    end
    local popupKey = AwardPopupKey(player, sessionInfo.session, sessionInfo.itemLink)
    if awardPopupKeys[popupKey] then
        return "duplicate"
    end
    local responseMeta = ResolveAwardResponse(sessionInfo, player, responseText)
    if not responseMeta then
        return "unresolved"
    end
    local evaluation = profile:EvaluateRCBisConflict({
        memberId = player,
        itemLink = sessionInfo.itemLink,
        response = responseMeta.response,
        responseId = responseMeta.responseId,
        typeCode = responseMeta.typeCode,
        isAwardReason = responseMeta.isAwardReason,
        excludeAwardKey = AwardKeyFromSessionHistory(sessionInfo, player),
    })
    if type(evaluation) ~= "table" then
        return "unavailable"
    end
    if not evaluation.qualified then
        return "not_bis"
    end
    if evaluation.uncertain or not evaluation.conflict then
        if evaluation.uncertain then
            DebugInfo("Skipping double-BiS award popup for %s; opportunity state is unresolved", player)
            return "unresolved"
        end
        return "clear"
    end
    local slotLabel = evaluation.slotLabel
    if type(slotLabel) ~= "string" or slotLabel == "" then
        return "unresolved"
    end
    local message = string.format(
        "%s was awarded %s even though they already used their BiS opportunity for the %s slot.\n\nIf this is intentional, no action is required. If their tracked BiS state is incorrect, it can be overridden in the Loot Helper settings.",
        player,
        tostring(sessionInfo.itemLink),
        slotLabel
    )
    awardPopupKeys[popupKey] = true
    if not Integration.ShowInformationalPopup(message) then
        awardPopupKeys[popupKey] = nil
        return "unavailable"
    end
    DebugInfo("Showed double-BiS award popup for %s", player)
    return "popup"
end

-- Direct candidate responses are whispers to the current Master Looter.
-- Group and guild traffic is inflated only when the sender is that ML.
local function NonMLMayDecode(distribution, sender)
    if distribution ~= "WHISPER" then
        return false, "not_ml"
    end
    if not Integration.LocalPlayerIsCurrentMasterLooter() then
        return false, "not_ml"
    end
    local player = Integration.NormalizeRCPlayerId(sender)
    local profile = Integration.GetSessionProfile()
    local member = player and profile and profile.getMemberByID and profile:getMemberByID(player) or nil
    if not member then
        DebugInfo("Ignoring RC whisper from %s before decode; sender is not a session profile member", tostring(sender))
        return false, "untrusted"
    end
    return true
end

function Integration.HandleIncomingMessage(prefix, message, distribution, sender)
    if prefix ~= Integration.RC_PREFIX then
        return "ignored"
    end
    if not Integration.IsSpectrumSessionActive() then
        return "no_session"
    end
    if type(message) ~= "string" or message == "" then
        return "ignored"
    end
    if #message > Integration.MAX_COMPRESSED_BYTES then
        DebugInfo("Ignoring oversized RC payload from %s (%d bytes)", tostring(sender), #message)
        return "too_large"
    end
    -- Authenticate before inflate. History, change_response, and session_end
    -- stay Master-Looter-authoritative. A candidate response is a whisper to
    -- the current ML from a session-profile member.
    if not Integration.SenderIsCurrentMasterLooter(sender) then
        local allowed, reason = NonMLMayDecode(distribution, sender)
        if not allowed then
            if reason ~= "untrusted" then
                DebugInfo("Ignoring RC payload from non-ML sender %s before decode", tostring(sender))
            end
            return reason or "not_ml"
        end
    end
    local decoded = Integration.DecodeHistoryPayload(message)
    local command = decoded and decoded.command
    if not Integration.SenderIsCurrentMasterLooter(sender) and command ~= "response" then
        DebugInfo("Ignoring non-response RC payload from %s", tostring(sender))
        return "not_ml"
    end
    if command == "history" then
        if not Integration.SenderIsCurrentMasterLooter(sender) then
            DebugInfo("Ignoring RC history from non-ML sender %s", tostring(sender))
            return "not_ml"
        end
        if not decoded.ok then
            return "ignored"
        end
        return Integration.HandleHistory(sender, decoded.winner, decoded.history, "acecomm")
    end
    if command == "response" then
        return Integration.HandleCandidateResponse(sender, decoded.data)
    end
    if command == "change_response" then
        return Integration.HandleChangeResponse(sender, decoded.data)
    end
    if command == "session_end" then
        if not Integration.SenderIsCurrentMasterLooter(sender) then
            return "not_ml"
        end
        Integration.ClearBisProtectionMemory()
        return "session_end"
    end
    if not Integration.SenderIsCurrentMasterLooter(sender) then
        return "not_ml"
    end
    return "ignored"
end

function Integration.HandleLocalHistory(history, winner)
    return Integration.HandleHistory(GetLocalPlayerId(), winner, history, "local")
end

function commReceiver.OnCommReceived(_self, prefix, message, distribution, sender)
    if not commReceiver._registered then
        return
    end
    Integration.HandleIncomingMessage(prefix, message, distribution, sender)
end

function Integration.RegisterListener(aceComm)
    if commReceiver._registered then
        return false
    end
    aceComm = aceComm or Integration.ResolveLibraries().AceComm
    if not aceComm or not aceComm.Embed then
        return false
    end
    if not commReceiver._embedded then
        aceComm:Embed(commReceiver)
        commReceiver._embedded = true
    end
    commReceiver:RegisterComm(Integration.RC_PREFIX, "OnCommReceived")
    commReceiver._registered = true
    return true
end

function Integration.UnregisterListener()
    if not commReceiver._registered then
        return false
    end
    if commReceiver.UnregisterAllComm then
        commReceiver:UnregisterAllComm()
    end
    commReceiver._registered = false
    return true
end

function Integration.IsListenerRegistered()
    return commReceiver._registered == true
end

local function HandleLocalHistoryMessage(_, history, winner)
    Integration.HandleLocalHistory(history, winner)
end

local function HandleAwardSuccessMessage(_, session, winner, status, itemLink, responseText)
    Integration.HandleAwardSuccess(session, winner, status, itemLink, responseText)
end

function Integration.RegisterRCMessages()
    if messageReceiver._registered then
        return false
    end

    local aceEvent
    local libStub = _G.LibStub
    if type(libStub) == "function" or type(libStub) == "table" then
        local ok, lib = pcall(libStub, "AceEvent-3.0", true)
        if ok then
            aceEvent = lib
        end
    end
    if aceEvent and aceEvent.Embed then
        if not messageReceiver._embedded then
            aceEvent:Embed(messageReceiver)
            messageReceiver._embedded = true
        end
        if messageReceiver.RegisterMessage then
            messageReceiver:RegisterMessage("RCMLLootHistorySend", HandleLocalHistoryMessage)
            messageReceiver:RegisterMessage("RCMLAwardSuccess", HandleAwardSuccessMessage)
            messageReceiver._registered = true
            messageReceiver._fallbackOnRC = false
            return true
        end
    end

    -- Fallback: subscribe on the RC addon object. Do not later UnregisterMessage
    -- there; that can drop other subscribers on the same embed.
    local rc = _G.RCLootCouncil
    if not (rc and rc.RegisterMessage) then
        return false
    end
    rc:RegisterMessage("RCMLLootHistorySend", HandleLocalHistoryMessage)
    rc:RegisterMessage("RCMLAwardSuccess", HandleAwardSuccessMessage)
    messageReceiver._registered = true
    messageReceiver._fallbackOnRC = true
    return true
end

function Integration.UnregisterRCMessages()
    if not messageReceiver._registered then
        return false
    end
    if messageReceiver._fallbackOnRC then
        return false
    end
    if messageReceiver.UnregisterMessage then
        messageReceiver:UnregisterMessage("RCMLLootHistorySend")
        messageReceiver:UnregisterMessage("RCMLAwardSuccess")
    end
    messageReceiver._registered = false
    return true
end

function Integration.AreRCMessagesRegistered()
    return messageReceiver._registered == true
end

function Integration.ReconcileListener(reason)
    if Integration.IsSpectrumSessionActive() then
        Integration.RegisterListener()
        Integration.RegisterRCMessages()
        return "active"
    end
    Integration.UnregisterListener()
    Integration.UnregisterRCMessages()
    Integration.ClearSessionMemory()
    return "inactive"
end

function Integration.InstallSessionHooks()
    if hooksInstalled then
        return false
    end
    local SF = ParentAddon()
    local sync = SF and SF.LootHelperSync
    if not sync or type(hooksecurefunc) ~= "function" then
        return false
    end
    for i = 1, #SESSION_HOOKS do
        local methodName = SESSION_HOOKS[i]
        if type(sync[methodName]) == "function" then
            hooksecurefunc(sync, methodName, function()
                Integration.ReconcileListener(methodName)
            end)
        end
    end
    hooksInstalled = true
    return true
end

function Integration.AreHooksInstalled()
    return hooksInstalled
end

local function GetEditableRCConfig(profile)
    if not profile then
        return nil
    end
    if profile.GetEditableRCLootCouncilIntegrationConfig then
        return profile:GetEditableRCLootCouncilIntegrationConfig()
    end
    if profile.GetRCLootCouncilIntegrationConfig then
        return profile:GetRCLootCouncilIntegrationConfig()
    end
    return nil
end

local function RecordingEnabled()
    -- Award-time recording uses the accepted config only. Unpublished
    -- out-of-session drafts must not change recording until they are minted.
    local profile = Integration.GetSettingsProfile()
    local cfg = profile and profile.GetRCLootCouncilIntegrationConfig
        and profile:GetRCLootCouncilIntegrationConfig()
    return cfg and cfg.recordAwards and true or false
end

local function AwardReasonHistoryResponseId(entry)
    local sort = tonumber(entry and entry.sort)
    if not sort then
        return nil
    end
    return sort - 400
end

function Integration.AwardReasonHistoryResponseId(entry)
    return AwardReasonHistoryResponseId(entry)
end

-- The Master Looter "Number of buttons" / "Number of reasons" sliders only
-- enable the leading rows. RC still stores the unused rows, including names
-- that were removed from the active set, so the dropdown must not list them.
local function ActiveSliderCount(profile, key)
    local count = tonumber(profile and profile[key])
    if not count then
        return nil
    end
    if count < 0 then
        count = 0
    end
    return math.floor(count)
end

local function GetRCResponseOptions()
    local options = {}
    local seen = {}
    local function add(entry)
        if type(entry) ~= "table" or type(entry.key) ~= "string" or seen[entry.key] then
            return
        end
        seen[entry.key] = true
        -- Settings dropdowns render `label`. `value` stays the ctx key used
        -- for award matching, and `textLabel` is the raw RC response text.
        local displayLabel = entry.label or entry.text
        options[#options + 1] = {
            value = entry.key,
            label = displayLabel,
            text = displayLabel,
            typeCode = entry.typeCode,
            responseId = entry.responseId,
            isAwardReason = entry.isAwardReason and true or false,
            textLabel = entry.text,
        }
    end
    local rc = _G.RCLootCouncil
    local db = rc and rc.Getdb and rc:Getdb() or (rc and rc.db)
    local profile = db and (db.profile or db)
    local responses = profile and profile.responses
    local activeButtons = ActiveSliderCount(profile, "numButtons")
    if type(responses) == "table" then
        for typeCode, group in pairs(responses) do
            if type(group) == "table" then
                for id, entry in pairs(group) do
                    local numericId = tonumber(id)
                    local withinActiveButtons = (not activeButtons) or (numericId and numericId >= 1 and numericId <= activeButtons)
                    if type(entry) == "table" and numericId and withinActiveButtons then
                        local text = entry.text or entry.label or entry.name
                        if type(text) == "string" and strtrim(text) ~= "" then
                            add({
                                key = string.format("ctx:%s|%s|0", tostring(typeCode), tostring(numericId)),
                                text = strtrim(text),
                                label = string.format("%s (%s #%s)", strtrim(text), tostring(typeCode), tostring(numericId)),
                                typeCode = tostring(typeCode),
                                responseId = numericId,
                                isAwardReason = false,
                            })
                        end
                    end
                end
            end
        end
    end
    local awardReasons = profile and profile.awardReasons
    local activeReasons = ActiveSliderCount(profile, "numAwardReasons")
    if type(awardReasons) == "table" then
        for index, entry in ipairs(awardReasons) do
            if activeReasons and index > activeReasons then
                break
            end
            if type(entry) == "table" then
                local text = entry.text or entry.label
                local responseId = AwardReasonHistoryResponseId(entry)
                if type(text) == "string" and strtrim(text) ~= "" and responseId ~= nil then
                    add({
                        key = string.format("ctx:awardReason|%s|1", tostring(responseId)),
                        text = strtrim(text),
                        label = string.format("%s (award reason #%s)", strtrim(text), tostring(responseId)),
                        responseId = responseId,
                        isAwardReason = true,
                    })
                end
            end
        end
    end
    table.sort(options, function(a, b)
        return tostring(a.text) < tostring(b.text)
    end)
    return options
end

function Integration.GetRCResponseOptions()
    return GetRCResponseOptions()
end

local function SelectedBisOption(key)
    if type(key) ~= "string" then
        return nil
    end
    for _, option in ipairs(GetRCResponseOptions()) do
        if option.value == key then
            return {
                text = option.textLabel or option.text,
                typeCode = option.typeCode,
                responseId = option.responseId,
                isAwardReason = option.isAwardReason,
            }
        end
    end
    return key
end

local function GetProfile()
    return Integration.GetSettingsProfile()
end

-- Same effective-admin contract as Loot Helper Settings: Preview non-admin
-- and real non-admins evaluate false for the renderer isAdmin predicate.
local function IsSettingsAdmin()
    local profile = GetProfile()
    local SF = ParentAddon()
    local Imp = SF and SF.LootHelperImpersonation
    if Imp and Imp.IsEffectiveLocalAdmin then
        local ok, res = pcall(Imp.IsEffectiveLocalAdmin, Imp, profile)
        if ok then
            return res and true or false
        end
    end
    if profile and profile.IsCurrentUserAdmin then
        local ok, res = pcall(profile.IsCurrentUserAdmin, profile)
        if ok then
            return res and true or false
        end
    end
    return false
end

local function RefreshSettingsPanel(panel)
    local SF = ParentAddon()
    local renderer = SF and SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
    if renderer and renderer.Refresh then
        renderer:Refresh(panel)
    end
end

function Integration.RegisterSettingsPage()
    if pageRegistered then
        return false
    end
    local SF = ParentAddon()
    if not (SF and SF.SettingsUI and SF.SettingsUI.RegisterPage) then
        return false
    end

    local Page = {
        id = Integration.PAGE_ID,
        categoryId = "lootHelper",
        name = "RC Loot Council",
        navLabel = "RC Loot Council",
        description = "Record RC Loot Council awards in Spectrum Loot Logs for the active profile.",
        order = 24,
    }

    function Page.Build(_self, panel)
        settingsPanel = panel
        local renderer = SF.SettingsUI.DefinitionRenderer
        if not renderer then
            return
        end

        renderer:Build(panel, {
            isAdmin = function()
                return IsSettingsAdmin()
            end,
            sections = {
                {
                    id = "about",
                    title = "RC Loot Council Integration",
                    intro = "When this child addon is enabled and a Spectrum Loot Helper session is active, finalized RC Loot Council awards can be recorded in Loot Logs. Settings belong to the active Loot Helper profile and sync with that profile's snapshot.",
                    items = {
                        { type = "help", text = "The Loot Log Author is the RC master looter who awarded the item. The Spectrum admin who records the event must still be a profile admin.", indent = "label" },
                    },
                },
                {
                    id = "recording",
                    title = "Recording",
                    items = {
                        {
                            type = "checkbox",
                            label = "Record RC Loot Council Awards in Loot Logs",
                            adminOnly = true,
                            tooltip = "When enabled, eligible Spectrum admins record finalized RC awards for members of the active profile.",
                            get = function()
                                local cfg = GetEditableRCConfig(GetProfile())
                                if not cfg then
                                    return true
                                end
                                return cfg.recordAwards
                            end,
                            set = function(value)
                                local profile = GetProfile()
                                if profile and profile.SetRCLootCouncilRecordAwards then
                                    profile:SetRCLootCouncilRecordAwards(value and true or false)
                                end
                                RefreshSettingsPanel(panel)
                            end,
                        },
                        {
                            type = "checkbox",
                            label = "Record all award types",
                            adminOnly = true,
                            tooltip = "When enabled, every RC response label is recorded. When disabled, only the custom allow-list is recorded.",
                            visible = function()
                                local cfg = GetEditableRCConfig(GetProfile())
                                if not cfg then
                                    return true
                                end
                                return cfg.recordAwards
                            end,
                            get = function()
                                local cfg = GetEditableRCConfig(GetProfile())
                                if not cfg then
                                    return true
                                end
                                return cfg.recordAllAwardTypes
                            end,
                            set = function(value)
                                local profile = GetProfile()
                                if profile and profile.SetRCLootCouncilRecordAllAwardTypes then
                                    profile:SetRCLootCouncilRecordAllAwardTypes(value and true or false)
                                end
                                RefreshSettingsPanel(panel)
                            end,
                        },
                    },
                },
                {
                    id = "allowList",
                    title = "Allowed Award Types",
                    condition = function()
                        local cfg = GetEditableRCConfig(GetProfile())
                        if not cfg then
                            return false
                        end
                        return cfg.recordAwards and not cfg.recordAllAwardTypes
                    end,
                    items = {
                        { type = "help", text = "Matching is case-insensitive after trimming. The original RC response text is stored in the Loot Log.", indent = "label" },
                        {
                            type = "editboxButton",
                            label = "Add award type",
                            hint = "Need",
                            buttonText = "Add",
                            buttonWidth = 80,
                            editWidth = 180,
                            adminOnly = true,
                            onSubmit = function(ctx, text, editBox)
                                ctx.section:ClearMessage()
                                local profile = GetProfile()
                                if not (profile and profile.AddRCLootCouncilAllowedResponse) then
                                    ctx.section:SetMessage("No active profile.", "error")
                                    return
                                end
                                local ok, err = profile:AddRCLootCouncilAllowedResponse(text)
                                if not ok then
                                    ctx.section:SetMessage(err or "Could not add award type.", "error")
                                    return
                                end
                                editBox:SetText("")
                                ctx.section:SetMessage("Award type added.", "success")
                                ctx.pageBuilder:Refresh()
                            end,
                        },
                        {
                            type = "scrollList",
                            label = "Allowed types",
                            adminOnly = true,
                            height = 140,
                            rowHeight = 20,
                            removeAtlas = "common-icon-redx",
                            compactColumns = true,
                            getItems = function()
                                local cfg = GetEditableRCConfig(GetProfile())
                                if not cfg then
                                    return {}
                                end
                                local items = {}
                                for _, value in ipairs(cfg.allowedResponses or {}) do
                                    items[#items + 1] = {
                                        id = value,
                                        text = value,
                                        canRemove = true,
                                    }
                                end
                                return items
                            end,
                            onRemove = function(ctx, item)
                                local profile = GetProfile()
                                if not (profile and profile.RemoveRCLootCouncilAllowedResponse) then
                                    return
                                end
                                local ok, err = profile:RemoveRCLootCouncilAllowedResponse(item.id)
                                if not ok then
                                    ctx.section:SetMessage(err or "Could not remove award type.", "error")
                                    return
                                end
                                ctx.section:SetMessage("Award type removed.", "success")
                                ctx.pageBuilder:Refresh()
                            end,
                        },
                    },
                },
                {
                    id = "bisResponses",
                    title = "BiS-Qualifying Responses",
                    items = {
                        { type = "help", text = "When recording is on, every BiS-qualified response is recorded. Configuration is kept while recording is off, but it is inactive until recording is turned back on. Only future RC awards use this list. Historical BiS outcomes are never reinterpreted.", indent = "label" },
                        {
                            type = "dropdownIconButton",
                            label = "Add from RC Loot Council",
                            adminOnly = true,
                            defaultText = "Select response",
                            enabled = function()
                                return RecordingEnabled()
                            end,
                            visible = function()
                                return #GetRCResponseOptions() > 0
                            end,
                            options = function()
                                return GetRCResponseOptions()
                            end,
                            get = function() return panel.__sfBisResponseSelected end,
                            set = function(value) panel.__sfBisResponseSelected = value end,
                            iconAtlas = "common-icon-plus",
                            iconToolTip = "Add the selected RC response as BiS-qualifying",
                            iconEnabled = function()
                                return RecordingEnabled() and panel.__sfBisResponseSelected ~= nil
                            end,
                            onIconClick = function(ctx)
                                local profile = GetProfile()
                                if not (profile and profile.AddRCLootCouncilBisResponse) then
                                    ctx.section:SetMessage("No active profile.", "error")
                                    return
                                end
                                if not RecordingEnabled() then
                                    ctx.section:SetMessage("Turn on Record RC Loot Council awards before changing BiS responses.", "error")
                                    return
                                end
                                local ok, err = profile:AddRCLootCouncilBisResponse(SelectedBisOption(panel.__sfBisResponseSelected))
                                if not ok then
                                    ctx.section:SetMessage(err or "Could not add BiS response.", "error")
                                    return
                                end
                                ctx.section:SetMessage("BiS response added. Future awards only.", "success")
                                ctx.pageBuilder:Refresh()
                            end,
                        },
                        {
                            type = "editboxButton",
                            label = "Add BiS response",
                            hint = "BiS",
                            buttonText = "Add",
                            buttonWidth = 80,
                            editWidth = 180,
                            adminOnly = true,
                            enabled = function()
                                return RecordingEnabled()
                            end,
                            onSubmit = function(ctx, text, editBox)
                                ctx.section:ClearMessage()
                                local profile = GetProfile()
                                if not (profile and profile.AddRCLootCouncilBisResponse) then
                                    ctx.section:SetMessage("No active profile.", "error")
                                    return
                                end
                                if not RecordingEnabled() then
                                    ctx.section:SetMessage("Turn on Record RC Loot Council awards before changing BiS responses.", "error")
                                    return
                                end
                                local ok, err = profile:AddRCLootCouncilBisResponse(text)
                                if not ok then
                                    ctx.section:SetMessage(err or "Could not add BiS response.", "error")
                                    return
                                end
                                editBox:SetText("")
                                ctx.section:SetMessage("BiS response added. Future awards only.", "success")
                                ctx.pageBuilder:Refresh()
                            end,
                        },
                        {
                            type = "scrollList",
                            label = "BiS responses",
                            adminOnly = true,
                            height = 140,
                            rowHeight = 20,
                            removeAtlas = "common-icon-redx",
                            compactColumns = true,
                            enabled = function()
                                return RecordingEnabled()
                            end,
                            getItems = function()
                                local cfg = GetEditableRCConfig(GetProfile())
                                if not cfg then
                                    return {}
                                end
                                local items = {}
                                for _, value in ipairs(cfg.bisResponses or {}) do
                                    local label = value.text or value.key or tostring(value)
                                    if value.isAwardReason then
                                        label = string.format("%s [award reason #%s]", label, tostring(value.responseId))
                                    elseif value.typeCode and value.responseId ~= nil then
                                        label = string.format("%s [%s #%s]", label, tostring(value.typeCode), tostring(value.responseId))
                                    end
                                    items[#items + 1] = {
                                        id = value.key or value.text,
                                        text = label,
                                        canRemove = true,
                                    }
                                end
                                return items
                            end,
                            onRemove = function(ctx, item)
                                local profile = GetProfile()
                                if not (profile and profile.RemoveRCLootCouncilBisResponse) then
                                    return
                                end
                                if not RecordingEnabled() then
                                    ctx.section:SetMessage("Turn on Record RC Loot Council awards before changing BiS responses.", "error")
                                    return
                                end
                                local ok, err = profile:RemoveRCLootCouncilBisResponse(item.id)
                                if not ok then
                                    ctx.section:SetMessage(err or "Could not remove BiS response.", "error")
                                    return
                                end
                                ctx.section:SetMessage("BiS response removed. Future awards only.", "success")
                                ctx.pageBuilder:Refresh()
                            end,
                        },
                    },
                },
            },
        })
    end

    function Page.Refresh(_self, panel)
        settingsPanel = panel
        RefreshSettingsPanel(panel)
    end

    SF.SettingsUI:RegisterPage(Page)
    pageRegistered = true
    return true
end

function Integration.Init(reason)
    if initialized then
        Integration.ReconcileListener(reason or "Init(reenter)")
        return false
    end
    initialized = true
    Integration.RegisterSettingsPage()
    Integration.InstallSessionHooks()
    Integration.ReconcileListener(reason or "Init")
    DebugInfo("RC Loot Council Integration initialized")
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
            if loadedName == Integration.ADDON_NAME then
                Integration.Init("ADDON_LOADED")
            elseif loadedName == "RCLootCouncil" or loadedName == "RCLootCouncil2" then
                Integration.ReconcileListener(loadedName)
            end
        elseif event == "PLAYER_LOGIN" then
            Integration.InstallSessionHooks()
            Integration.RegisterSettingsPage()
            Integration.ReconcileListener("PLAYER_LOGIN")
        end
    end)
    return eventFrame
end

EnsureEventFrame()

if ns ~= _G then
    ns.RCLootCouncilIntegration = Integration
end
