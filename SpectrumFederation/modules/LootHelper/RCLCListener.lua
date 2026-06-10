-- modules/LootHelper/RCLCListener.lua
-- Listens for RCLootCouncil addon messages to record loot awards in the Loot Log.
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
-- RC Loot Council Message Parsing
-- ============================================================================

-- Try to deserialize an RCLC message using AceSerializer (which RCLC uses)
-- RCLC format: serialized table where first element is the command string
local function TryDeserializeRCLC(text)
    if type(text) ~= "string" or text == "" then return nil end

    local AceSerializer = LibStub and LibStub("AceSerializer-3.0", true)
    if AceSerializer and AceSerializer.Deserialize then
        local ok, data = AceSerializer:Deserialize(text)
        if ok then return data end
    end

    return nil
end

-- Handle an incoming RCLC addon message
-- RCLC sends serialized tables; award messages typically contain:
-- command = "award", candidate/winner name, item link, response/roll type
local function OnRCLCMessage(prefix, message, distribution, sender)
    if prefix ~= RCLC_PREFIX then return end

    DVerbose("Received RCLC message from %s (dist=%s)", tostring(sender), tostring(distribution))

    local data = TryDeserializeRCLC(message)
    if type(data) ~= "table" then
        return
    end

    -- RCLC sends messages as { "command", arg1, arg2, ... } or { command = "...", ... }
    local command = data.command or data[1]
    if type(command) ~= "string" then return end
    command = command:lower()

    if command == "award" then
        -- Try to extract award info from various RCLC message formats
        local candidate = data.candidate or data[2]
        local itemLink = data.link or data.item or data[3]
        local response = data.response or data.rollType or data[4]

        if type(candidate) ~= "string" or candidate == "" then
            DVerbose("RCLC award: no candidate found")
            return
        end
        if type(itemLink) ~= "string" or itemLink == "" then
            DVerbose("RCLC award: no item link found")
            return
        end
        if type(response) ~= "string" or response == "" then
            response = "Unknown"
        end

        local normalizedMember = NormalizeName(candidate)
        if not normalizedMember then
            DWarn("RCLC award: could not normalize candidate name: %s", tostring(candidate))
            return
        end

        RecordLootAward(normalizedMember, itemLink, response, "RCLootCouncil")
    end
end

-- ============================================================================
-- Initialization
-- ============================================================================

Listener._initialized = Listener._initialized or false

function Listener:Init()
    if self._initialized then return end
    self._initialized = true

    -- Register to listen for RCLC addon messages
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(RCLC_PREFIX)
    end

    -- Create event frame to listen for CHAT_MSG_ADDON
    if not self._frame then
        self._frame = CreateFrame("Frame")
    end

    self._frame:RegisterEvent("CHAT_MSG_ADDON")
    self._frame:SetScript("OnEvent", function(_, event, prefix, message, distribution, sender)
        if event == "CHAT_MSG_ADDON" then
            OnRCLCMessage(prefix, message, distribution, sender)
        end
    end)

    -- Set up periodic dedup pruning (every 30 seconds)
    if not self._pruneTicker then
        self._pruneTicker = C_Timer and C_Timer.NewTicker and C_Timer.NewTicker(30, PruneDedup)
    end

    DInfo("RCLCListener initialized, listening for prefix: %s", RCLC_PREFIX)
end
