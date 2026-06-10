-- modules/LootHelper/RCLCListener.lua
-- Listens for RCLootCouncil addon messages to record loot awards in the Loot Log.
--
-- Integration strategy (in priority order):
-- 1. Hook RCLC's ML:Award function directly (most reliable, fires locally)
-- 2. Register via AceComm on the "RCLootCouncil" prefix for reassembled messages
-- 3. Both paths feed into the same RecordLootAward pipeline
local addonName, SF = ...

SF.RCLCListener = SF.RCLCListener or {}
local Listener = SF.RCLCListener

-- RC Loot Council uses "RCLootCouncil" as its primary addon message prefix
local RCLC_PREFIX = "RCLootCouncil"

-- Deduplication window in seconds to avoid duplicate log entries during sync
local DEDUP_WINDOW_SEC = 10
Listener._recentAwards = Listener._recentAwards or {}

-- ============================================================================
-- Helpers
-- ============================================================================

local function DInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info then
        SF.Debug:Info("RCLC_LISTENER", fmt, ...)
    end
end

local function DVerbose(fmt, ...)
    if SF.Debug and SF.Debug.Verbose then
        SF.Debug:Verbose("RCLC_LISTENER", fmt, ...)
    end
end

local function DWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn then
        SF.Debug:Warn("RCLC_LISTENER", fmt, ...)
    end
end

-- Check if a Loot Helper sync session is currently active
local function IsSessionActive()
    return SF.LootHelperSync
        and type(SF.LootHelperSync.IsSessionActive) == "function"
        and SF.LootHelperSync:IsSessionActive()
end

-- Get the active profile, or nil
local function GetActiveProfile()
    if SF.GetActiveProfile then
        return SF:GetActiveProfile()
    end
    return SF.lootHelperDB and SF.lootHelperDB.activeProfile
end

-- Normalize a player name to "Name-Realm" format
local function NormalizeName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name)
    end
    -- If no realm separator, add own realm
    if not name:find("-") then
        local realm = GetRealmName()
        if realm then
            realm = realm:gsub("%s+", "")
            return name .. "-" .. realm
        end
    end
    return name
end

-- Build a dedup key from member + itemLink
local function DedupKey(member, itemLink)
    return (member or "") .. "|" .. (itemLink or "")
end

-- Check if this award was already recorded recently
local function IsDuplicate(member, itemLink)
    local key = DedupKey(member, itemLink)
    local entry = Listener._recentAwards[key]
    if not entry then return false end
    local now = GetTime()
    if (now - entry) < DEDUP_WINDOW_SEC then
        return true
    end
    Listener._recentAwards[key] = nil
    return false
end

-- Mark this award as recently recorded
local function MarkRecorded(member, itemLink)
    local key = DedupKey(member, itemLink)
    Listener._recentAwards[key] = GetTime()
end

-- Periodically prune stale dedup entries
local function PruneDedup()
    local now = GetTime()
    for key, ts in pairs(Listener._recentAwards) do
        if (now - ts) >= DEDUP_WINDOW_SEC then
            Listener._recentAwards[key] = nil
        end
    end
end

-- ============================================================================
-- Log Creation
-- ============================================================================

-- Record a loot award into the active profile's loot log
-- @param member string "Name-Realm"
-- @param itemLink string WoW item link
-- @param rollType string Roll type (e.g. "Need", "Greed", "Mainspec")
-- @param source string|nil Source addon identifier
local function RecordLootAward(member, itemLink, rollType, source)
    if not IsSessionActive() then
        DVerbose("No active Loot Helper session; skipping loot award record")
        return
    end

    local profile = GetActiveProfile()
    if not profile then
        DVerbose("No active profile; skipping loot award record")
        return
    end

    if IsDuplicate(member, itemLink) then
        DVerbose("Duplicate loot award for %s item %s; skipping", member, itemLink)
        return
    end

    local eventType = SF.LootLogEventTypes and SF.LootLogEventTypes.LOOT_AWARDED
    if not eventType then
        DWarn("LOOT_AWARDED event type not available")
        return
    end

    local eventData = SF.LootLog and SF.LootLog.GetEventDataTemplate and SF.LootLog.GetEventDataTemplate(eventType)
    if not eventData then
        DWarn("Could not get event data template for LOOT_AWARDED")
        return
    end

    eventData.member = member
    eventData.itemLink = itemLink
    eventData.rollType = rollType
    if source then
        eventData.source = source
    end

    -- Create log with skipPermission since this is an automated integration entry
    -- Use "RCLootCouncil" as author to distinguish from manual entries
    local authorName = source or "RCLootCouncil"
    local log = SF.LootLog.new(eventType, eventData, {
        skipPermission = true,
        author = authorName,
    })

    if not log then
        DWarn("Failed to create LOOT_AWARDED log for %s", member)
        return
    end

    -- Add to profile
    if profile.AddLootLog and type(profile.AddLootLog) == "function" then
        profile:AddLootLog(log)
    elseif profile.logs and type(profile.logs) == "table" then
        table.insert(profile.logs, log)
    else
        DWarn("Cannot add log to profile: no AddLootLog method or logs table")
        return
    end

    MarkRecorded(member, itemLink)
    DInfo("Recorded loot award: %s received %s (%s)", member, itemLink, rollType)

    -- Notify data changed so UI refreshes
    if SF.LootHelperEvents and SF.LootHelperEvents.NotifyDataChanged then
        SF.LootHelperEvents:NotifyDataChanged("LOOT_AWARDED", {
            member = member,
            itemLink = itemLink,
            rollType = rollType,
        })
    end
end

-- ============================================================================
-- RC Loot Council Message Parsing (AceComm path)
-- ============================================================================

-- Try to deserialize an RCLC message using AceSerializer (provided by RCLC)
-- RCLC format after AceComm reassembly: AceSerializer-encoded table
local function TryDeserializeRCLC(text)
    if type(text) ~= "string" or text == "" then return nil end

    local AceSerializer = LibStub and LibStub("AceSerializer-3.0", true)
    if not AceSerializer or not AceSerializer.Deserialize then
        DVerbose("AceSerializer-3.0 not available for deserialization")
        return nil
    end

    local ok, data = AceSerializer:Deserialize(text)
    if ok then return data end

    -- RCLC v3+ may use LibDeflate compression before serialization
    local LibDeflate = LibStub and LibStub("LibDeflate", true)
    if LibDeflate and LibDeflate.DecodeForWoWAddonChannel then
        local decoded = LibDeflate:DecodeForWoWAddonChannel(text)
        if decoded then
            local decompressed = LibDeflate:DecompressDeflate(decoded)
            if decompressed then
                local ok2, data2 = AceSerializer:Deserialize(decompressed)
                if ok2 then return data2 end
            end
        end
    end

    return nil
end

-- Extract award data from a deserialized RCLC message table.
-- RCLC message format (array-style): {"command", arg1, arg2, ...}
-- For "award" command, typical layout:
--   { "award", session(int), winner(string), response(string|table), reason(string), ... }
-- Some versions include item info inline; others store it in session objects.
-- We search all values for the candidate name and item link.
local function ExtractAwardFields(data)
    local candidate = nil
    local itemLink = nil
    local response = nil

    -- Strategy: walk numeric indices looking for string fields
    -- data[1] = "award" (command), data[2..n] = arguments
    for i = 2, #data do
        local val = data[i]
        if type(val) == "string" then
            -- Item links contain "|Hitem:" or "|hitem:"
            if not itemLink and val:find("|Hitem:") then
                itemLink = val
            elseif not candidate and val:find("-") and not val:find("|") then
                -- Likely a "Name-Realm" string (no pipe chars = not an item link)
                candidate = val
            elseif not candidate and val:match("^[A-Z]") and not val:find("|") then
                -- Plain name without realm
                candidate = val
            elseif not response and not val:find("|") then
                -- A non-link string that isn't the candidate is likely the response
                if candidate then
                    response = val
                end
            end
        elseif type(val) == "table" then
            -- RCLC sometimes nests item info or candidate info in sub-tables
            if not itemLink and type(val.link) == "string" then
                itemLink = val.link
            end
            if not candidate and type(val.name) == "string" then
                candidate = val.name
            end
            if not response and type(val.response) == "string" then
                response = val.response
            end
        end
    end

    -- Also check named keys (some RCLC versions use these)
    if not candidate and type(data.candidate) == "string" then
        candidate = data.candidate
    end
    if not candidate and type(data.winner) == "string" then
        candidate = data.winner
    end
    if not itemLink and type(data.link) == "string" then
        itemLink = data.link
    end
    if not itemLink and type(data.item) == "string" then
        itemLink = data.item
    end
    if not response and type(data.response) == "string" then
        response = data.response
    end
    if not response and type(data.reason) == "string" then
        response = data.reason
    end

    return candidate, itemLink, response
end

-- AceComm callback: handles fully reassembled messages from RCLC
-- @param prefix string The addon message prefix
-- @param message string The full reassembled message text
-- @param distribution string Distribution channel (RAID, PARTY, etc.)
-- @param sender string Sender name
function Listener:OnRCLCCommReceived(prefix, message, distribution, sender)
    if prefix ~= RCLC_PREFIX then return end

    DVerbose("Received RCLC comm from %s (dist=%s, len=%d)", tostring(sender), tostring(distribution), #message)

    local data = TryDeserializeRCLC(message)
    if type(data) ~= "table" then
        DVerbose("Could not deserialize RCLC message from %s", tostring(sender))
        return
    end

    -- RCLC sends messages as { "command", arg1, arg2, ... }
    local command = data[1]
    if type(command) ~= "string" then
        -- Some formats use data.command
        command = data.command
    end
    if type(command) ~= "string" then return end
    command = command:lower()

    DVerbose("RCLC command: %s from %s", command, tostring(sender))

    if command == "award" or command == "awarded" then
        local candidate, itemLink, response = ExtractAwardFields(data)

        if not candidate or candidate == "" then
            DVerbose("RCLC award: no candidate found in message from %s", tostring(sender))
            return
        end
        if not itemLink or itemLink == "" then
            DVerbose("RCLC award: no item link found in message from %s", tostring(sender))
            return
        end
        if not response or response == "" then
            response = "Unknown"
        end

        local normalizedMember = NormalizeName(candidate)
        if not normalizedMember then
            DWarn("RCLC award: could not normalize candidate name: %s", tostring(candidate))
            return
        end

        DInfo("RCLC award detected: %s -> %s (%s)", tostring(normalizedMember), tostring(itemLink), tostring(response))
        RecordLootAward(normalizedMember, itemLink, response, "RCLootCouncil")
    end
end

-- ============================================================================
-- RCLC Direct Hook (preferred path)
-- ============================================================================

-- Try to hook into RCLootCouncil's ML (Master Looter) module Award function.
-- This fires locally when the ML awards an item, giving us direct access to
-- structured data without needing to parse serialized messages.
local function TryHookRCLC()
    -- RCLootCouncil registers itself via AceAddon; check _G or LibStub
    local RCLC = _G.RCLootCouncil
    if not RCLC then
        -- Try AceAddon lookup
        local AceAddon = LibStub and LibStub("AceAddon-3.0", true)
        if AceAddon and AceAddon.GetAddon then
            local ok, addon = pcall(AceAddon.GetAddon, AceAddon, "RCLootCouncil")
            if ok then RCLC = addon end
        end
    end

    if not RCLC then
        DVerbose("RCLootCouncil addon object not found; hook unavailable")
        return false
    end

    -- RCLC fires "RCMLAwardSuccess" on its comms object or directly
    -- Try to register a callback for award events
    if RCLC.RegisterCallback then
        -- Try known callback names across RCLC versions
        local callbackNames = {
            "RCMLAwardSuccess",
            "RCLootCouncilAward",
        }
        for _, cbName in ipairs(callbackNames) do
            local ok = pcall(RCLC.RegisterCallback, RCLC, Listener, cbName, function(_, event, ...)
                DVerbose("RCLC callback fired: %s", tostring(event))
                Listener:_HandleRCLCCallback(event, ...)
            end)
            if ok then
                DInfo("Registered RCLC callback: %s", cbName)
            end
        end
    end

    -- Hook the ML module's Award function for the most reliable capture
    local ML = RCLC.GetModule and RCLC:GetModule("RCLootCouncilML", true)
        or RCLC.GetModule and RCLC:GetModule("ML", true)
    if ML and ML.Award and type(ML.Award) == "function" then
        hooksecurefunc(ML, "Award", function(self2, session, winner, response, reason, ...)
            DVerbose("RCLC ML:Award hook fired (session=%s winner=%s)", tostring(session), tostring(winner))
            Listener:_HandleMLAward(session, winner, response, reason, ML)
        end)
        DInfo("Hooked RCLootCouncil ML:Award")
        return true
    end

    DVerbose("RCLC ML module or Award function not found")
    return false
end

-- Handle data from the ML:Award hook
function Listener:_HandleMLAward(session, winner, response, reason, ML)
    -- winner is typically "Name-Realm"
    if type(winner) ~= "string" or winner == "" then return end

    -- Get item link from the ML's loot table if available
    local itemLink = nil
    if ML and ML.lootTable and type(session) == "number" then
        local lootEntry = ML.lootTable[session]
        if type(lootEntry) == "table" then
            itemLink = lootEntry.link or lootEntry.item
        end
    end

    -- Resolve response text
    local responseText = nil
    if type(response) == "table" and type(response.text) == "string" then
        responseText = response.text
    elseif type(response) == "string" then
        responseText = response
    elseif type(reason) == "string" and reason ~= "" then
        responseText = reason
    end

    if not itemLink then
        DVerbose("RCLC ML:Award hook: no item link for session %s", tostring(session))
        return
    end

    local normalizedMember = NormalizeName(winner)
    if not normalizedMember then
        DWarn("RCLC ML:Award hook: could not normalize winner: %s", tostring(winner))
        return
    end

    DInfo("RCLC hook award: %s -> %s (%s)", normalizedMember, tostring(itemLink), tostring(responseText))
    RecordLootAward(normalizedMember, itemLink, responseText or "Unknown", "RCLootCouncil")
end

-- Handle RCLC callback events
function Listener:_HandleRCLCCallback(event, ...)
    -- Callback args vary by version; try to extract useful info
    local args = {...}
    local candidate, itemLink, response

    for i = 1, #args do
        local val = args[i]
        if type(val) == "string" then
            if not itemLink and val:find("|Hitem:") then
                itemLink = val
            elseif not candidate and val:find("-") and not val:find("|") then
                candidate = val
            elseif not candidate and val:match("^[A-Z]") and not val:find("|") then
                candidate = val
            end
        elseif type(val) == "table" then
            if not itemLink and type(val.link) == "string" then
                itemLink = val.link
            end
            if not candidate and type(val.winner) == "string" then
                candidate = val.winner
            end
            if not response and type(val.response) == "string" then
                response = val.response
            end
        end
    end

    if not candidate or not itemLink then
        DVerbose("RCLC callback %s: insufficient data (candidate=%s, link=%s)",
            tostring(event), tostring(candidate), tostring(itemLink))
        return
    end

    local normalizedMember = NormalizeName(candidate)
    if not normalizedMember then return end

    RecordLootAward(normalizedMember, itemLink, response or "Unknown", "RCLootCouncil")
end

-- ============================================================================
-- Initialization
-- ============================================================================

Listener._initialized = Listener._initialized or false

function Listener:Init()
    if self._initialized then return end
    self._initialized = true

    -- Attempt direct RCLC hook (preferred - works even if message format changes)
    local hooked = TryHookRCLC()
    if hooked then
        DInfo("RCLC integration via direct hook (primary path)")
    end

    -- Always also register via AceComm for redundancy and for non-ML clients
    -- AceComm handles multi-part message reassembly that raw CHAT_MSG_ADDON cannot
    local AceComm = LibStub and LibStub("AceComm-3.0", true)
    if AceComm then
        AceComm:Embed(self)
        self:RegisterComm(RCLC_PREFIX, "OnRCLCCommReceived")
        DInfo("RCLC AceComm listener registered on prefix: %s", RCLC_PREFIX)
    else
        DWarn("AceComm-3.0 not available; falling back to raw CHAT_MSG_ADDON")
        -- Fallback: raw event listener (unreliable for multi-part messages)
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(RCLC_PREFIX)
        end
        if not self._frame then
            self._frame = CreateFrame("Frame")
        end
        self._frame:RegisterEvent("CHAT_MSG_ADDON")
        self._frame:SetScript("OnEvent", function(_, event, prefix, message, distribution, sender)
            if event == "CHAT_MSG_ADDON" and prefix == RCLC_PREFIX then
                self:OnRCLCCommReceived(prefix, message, distribution, sender)
            end
        end)
    end

    -- If RCLC wasn't loaded yet, try hooking when it loads
    if not hooked then
        if not self._hookFrame then
            self._hookFrame = CreateFrame("Frame")
        end
        self._hookFrame:RegisterEvent("ADDON_LOADED")
        self._hookFrame:SetScript("OnEvent", function(_, event, loadedAddon)
            if event == "ADDON_LOADED" and loadedAddon == "RCLootCouncil" then
                -- Delay slightly to let RCLC finish its own init
                if C_Timer and C_Timer.After then
                    C_Timer.After(2, function()
                        if TryHookRCLC() then
                            DInfo("RCLC hook installed after addon load")
                        end
                    end)
                else
                    TryHookRCLC()
                end
                self._hookFrame:UnregisterEvent("ADDON_LOADED")
            end
        end)
    end

    -- Set up periodic dedup pruning (every 30 seconds)
    if not self._pruneTicker then
        self._pruneTicker = C_Timer and C_Timer.NewTicker and C_Timer.NewTicker(30, PruneDedup)
    end

    DInfo("RCLCListener initialized")
end
