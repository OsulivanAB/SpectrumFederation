-- modules/UI/LootHelper/Style.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow

LH.Style = LH.Style or {}
local Style = LH.Style

local FONT_MAP = {
    ["Friz Quadrata"] = "Fonts\\FRIZQT__.TTF",
    ["Arial Narrow"] = "Fonts\\ARIALN.TTF",
    ["Morpheus"] = "Fonts\\MORPHEUS.TTF"
}

-- Get a global setting value with fallback
-- @param key string Setting key
-- @param fallback any Fallback value if setting is not found
-- @return any Setting value or fallback
local function GetGlobalSetting(key, fallback)
    -- Prefer SettingStore if available
    if SF.SettingStore and SF.SettingStore.Get then
        local v = SF.SettingsStore:Get("global." .. key)
        if v ~= nil then return v end
    end

    -- Fallback to raw SavedVariables
    local db = SpectrumFederationDB or SF.DB
    if db and db.global and db.global[key] ~= nil then
        return db.global[key]
    end

    return fallback
end

-- Resolve the font path and size based on global settings
-- @return string Font path
-- @return number Font size
-- @return string Font style name
function Style:ResolveFont()
    local fontStyle = GetGlobalSetting("fontStyle", "Friz Quadrata")
    local fontSize = tonumber(GetGlobalSetting("fontSize", 12)) or 12
    local fontPath = FONT_MAP[fontStyle] or STANDARD_TEXT_FONT
    return fontPath, fontSize, fontStyle
end

function Style:Apply(frame)
    if not frame then return end

    local fontPath, fontSize = self:ResolveFont()

    -- Title texts
    if frame.Title and frame.Title.ProfileName and frame.Title.ProfileName.SetFont then
        frame.Title.ProfileName:SetFont(fontPath, fontSize + 1, "OUTLINE")
    end
    if frame.Title and frame.Title.Session and frame.Title.Session.SetFont then
        frame.Title.Session:SetFont(fontPath, math.max(8, fontSize - 1), "OUTLINE")
    end

    -- Placeholder hook
    if frame.Content and frame.Content.Placeholder and frame.Content.Placeholder.SetFont then
        frame.Content.Placeholder:SetFont(fontPath, fontSize, "")
    end

    -- WindowStyle hook
    frame.__sfWindowStyle = GetGlobalSetting("windowStyle", "Default")
    -- TODO: implement real skins for Default/Compact/Minimal
end