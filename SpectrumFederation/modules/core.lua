local addonName, ns = ...

-- Local reference to Core module
local Core = ns.Core or {}
ns.Core = Core

-- OnPlayerLogin: Called when the player logs in
-- This will be expanded in future phases
function Core:OnPlayerLogin()
    -- Log to debug system
    if ns.Debug then
        ns.Debug:Info("PLAYER_LOGIN", "SpectrumFederation loaded")
    end
    
    -- Print success message to chat
    print("|cff00ff00Spectrum Federation|r loaded successfully!")
end
