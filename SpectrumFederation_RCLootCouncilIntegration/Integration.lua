-- Permanent optional child addon.
-- Records finalized RC Loot Council awards into Spectrum Loot Logs while a
-- Spectrum Loot Helper session is active. No SavedVariables and no raw
-- traffic persistence.

local addonName, ns = ...

ns = ns or {}
ns.RCLootCouncilIntegration = ns.RCLootCouncilIntegration or {}
local Integration = ns.RCLootCouncilIntegration

Integration.ADDON_NAME = addonName or "SpectrumFederation_RCLootCouncilIntegration"
Integration.PARENT_ADDON_NAME = "SpectrumFederation"
Integration.PAGE_ID = "lootHelperRCLootCouncil"
Integration.RC_PREFIX = "RCLC"
Integration.DEBUG_CATEGORY = "RCLC_INTEGRATION"

local initialized = false
local pageRegistered = false
local hooksInstalled = false
local settingsPanel = nil
local seenAwardKeys = {}
local warnedAwardKeys = {}

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

function Integration.GetActiveProfile()
    local SF = ParentAddon()
    if SF and SF.GetActiveProfile then
        local ok, profile = pcall(SF.GetActiveProfile, SF)
        if ok then
            return profile
        end
    end
    return SF and SF.lootHelperDB and SF.lootHelperDB.activeProfile or nil
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

function Integration.ClearSessionMemory()
    WipeTable(seenAwardKeys)
    WipeTable(warnedAwardKeys)
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
    local current = Integration.GetCurrentRCMasterLooter()
    if current and Integration.SamePlayer(sender, current) then
        return true
    end
    local rc = _G.RCLootCouncil
    if rc and type(rc.IsMasterLooter) == "function" then
        local ok, isML = pcall(rc.IsMasterLooter, rc, sender)
        if ok and isML == true then
            return true
        end
    end
    return false
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
    if type(raw) ~= "string" then
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
        local inflated = ld:DecompressDeflate(decodedBytes)
        return { serializer:Deserialize(inflated or "") }
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
    result.winner = data[1]
    result.history = data[2]
    if command == "history" and type(result.winner) == "string" and type(result.history) == "table" then
        result.ok = true
    end
    return result
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

function Integration.WarnNonMember(canonical)
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
    local profile = Integration.GetActiveProfile()
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

    local profile = Integration.GetActiveProfile()
    if not profile or not profile.TryAddRCLootCouncilAward then
        return "no_profile"
    end

    local member = profile.getMemberByID and profile:getMemberByID(canonical.winner)
    if not member then
        Integration.WarnNonMember(canonical)
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
    local canonical = SF.LootLog.BuildRCLootCouncilCanonical(awarder, winner, history)
    if not canonical then
        return "invalid"
    end
    return Integration.ProcessCanonicalAward(canonical, source or "history")
end

function Integration.HandleIncomingMessage(prefix, message, _distribution, sender)
    if prefix ~= Integration.RC_PREFIX then
        return "ignored"
    end
    if not Integration.IsSpectrumSessionActive() then
        return "no_session"
    end
    local decoded = Integration.DecodeHistoryPayload(message)
    if not decoded.ok then
        return "ignored"
    end
    if not Integration.SenderIsCurrentMasterLooter(sender) then
        DebugInfo("Ignoring RC history from non-ML sender %s", tostring(sender))
        return "not_ml"
    end
    return Integration.HandleHistory(sender, decoded.winner, decoded.history, "acecomm")
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

local function GetProfile()
    return Integration.GetActiveProfile()
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
                                local profile = GetProfile()
                                if not profile or not profile.GetRCLootCouncilIntegrationConfig then
                                    return true
                                end
                                return profile:GetRCLootCouncilIntegrationConfig().recordAwards
                            end,
                            set = function(value)
                                local profile = GetProfile()
                                if profile and profile.SetRCLootCouncilRecordAwards then
                                    profile:SetRCLootCouncilRecordAwards(value and true or false)
                                end
                                if panel.__sfPageBuilder then
                                    panel.__sfPageBuilder:Refresh()
                                    panel.__sfPageBuilder:Reflow()
                                end
                            end,
                        },
                        {
                            type = "checkbox",
                            label = "Record all award types",
                            adminOnly = true,
                            tooltip = "When enabled, every RC response label is recorded. When disabled, only the custom allow-list is recorded.",
                            visible = function()
                                local profile = GetProfile()
                                if not profile or not profile.GetRCLootCouncilIntegrationConfig then
                                    return true
                                end
                                return profile:GetRCLootCouncilIntegrationConfig().recordAwards
                            end,
                            get = function()
                                local profile = GetProfile()
                                if not profile or not profile.GetRCLootCouncilIntegrationConfig then
                                    return true
                                end
                                return profile:GetRCLootCouncilIntegrationConfig().recordAllAwardTypes
                            end,
                            set = function(value)
                                local profile = GetProfile()
                                if profile and profile.SetRCLootCouncilRecordAllAwardTypes then
                                    profile:SetRCLootCouncilRecordAllAwardTypes(value and true or false)
                                end
                                if panel.__sfPageBuilder then
                                    panel.__sfPageBuilder:Refresh()
                                    panel.__sfPageBuilder:Reflow()
                                end
                            end,
                        },
                    },
                },
                {
                    id = "allowList",
                    title = "Allowed Award Types",
                    visible = function()
                        local profile = GetProfile()
                        if not profile or not profile.GetRCLootCouncilIntegrationConfig then
                            return false
                        end
                        local cfg = profile:GetRCLootCouncilIntegrationConfig()
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
                                local profile = GetProfile()
                                if not profile or not profile.GetRCLootCouncilIntegrationConfig then
                                    return {}
                                end
                                local items = {}
                                for _, value in ipairs(profile:GetRCLootCouncilIntegrationConfig().allowedResponses) do
                                    items[#items + 1] = { id = value, label = value }
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
            },
        })
    end

    function Page.Refresh(_self, panel)
        settingsPanel = panel
        if SF.SettingsUI.DefinitionRenderer then
            SF.SettingsUI.DefinitionRenderer:Refresh(panel)
        end
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
