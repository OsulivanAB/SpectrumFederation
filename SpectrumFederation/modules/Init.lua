-- Grab the namespace
local addonName, SF = ...
-- TODO: Add the other init events here

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, loadedAddonName)
    if loadedAddonName ~= addonName then return end

    SF.SettingsStore:Init()
end)