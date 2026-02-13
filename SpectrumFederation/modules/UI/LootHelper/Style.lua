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
    -- Prefer SettingsStore if available
    if SF.SettingsStore and SF.SettingsStore.Get then
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

    if frame.Content and frame.Content.RosterView and frame.Content.RosterView.ApplyStyle then
        frame.Content.RosterView:ApplyStyle(fontPath, fontSize)
    end

    -- Apply window style
    self:ApplyWindowStyle(frame)
end

-- Apply window style (Default, Compact, or Minimal)
-- @param frame table The main window frame
-- @return nil
function Style:ApplyWindowStyle(frame)
    if not frame then return end

    local windowStyle = GetGlobalSetting("windowStyle", "Default")
    frame.__sfWindowStyle = windowStyle

    if SF.Debug then
        SF.Debug:Verbose("LH_STYLE", "Applying window style: %s", tostring(windowStyle))
    end

    if windowStyle == "Compact" then
        -- Compact: Thinner borders, reduced spacing
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 8,
            edgeSize = 10,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        frame:SetBackdropColor(0, 0, 0, 0.65)
        frame:SetBackdropBorderColor(0.55, 0.55, 0.55, 0.7)

        -- Adjust title background to be slightly smaller
        if frame.Title and frame.Title.BG then
            frame.Title.BG:SetColorTexture(0.08, 0.08, 0.08, 0.75)
        end

    elseif windowStyle == "Minimal" then
        -- Minimal: Very thin border, higher transparency
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = true,
            tileSize = 8,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 }
        })
        frame:SetBackdropColor(0, 0, 0, 0.50)
        frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)

        -- Make title background more transparent
        if frame.Title and frame.Title.BG then
            frame.Title.BG:SetColorTexture(0.08, 0.08, 0.08, 0.50)
        end

    else
        -- Default: Standard WoW tooltip-style borders
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 8,
            edgeSize = 12,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        frame:SetBackdropColor(0, 0, 0, 0.60)
        frame:SetBackdropBorderColor(0.65, 0.65, 0.65, 0.65)

        -- Standard title background
        if frame.Title and frame.Title.BG then
            frame.Title.BG:SetColorTexture(0.08, 0.08, 0.08, 0.85)
        end
    end
end