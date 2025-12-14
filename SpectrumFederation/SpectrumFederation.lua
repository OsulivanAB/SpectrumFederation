local addonName, ns = ...

-- Create event frame for addon initialization
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        print("|cff00ff00Spectrum Federation|r loaded successfully!")
    end
end)
