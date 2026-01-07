-- Grab the namespace
local addonName, SF = ...

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, loadedAddonName)
    if loadedAddonName ~= addonName then return end

    -- TODO: Refactor Debug so it has an init that we can put here

    if SF.SettingsStore and SF.SettingsStore.Init then
        SF.SettingsStore:Init()
    end

    if SF.SettingsUI and SF.SettingsUI.Init then
        SF.SettingsUI:Init()
    end
end)