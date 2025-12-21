-- Grab the namespace
local addonName, SF = ...

function SF:CreateSettingsUI()
    -- Create the canvas for the main panel frame
    local panel = CreateFrame("Frame", nil, UIParent)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        
        -- Create the category
        local category, layout = Settings.RegisterCanvasLayoutCategory(
            panel,
            "Spectrum Federation"
        )

        -- Add the Category to the Addons Menu
        Settings.RegisterAddOnCategory(category)

        -- Store the category & panel in our namespace for later use
        SF.SettingsCategory = category
        SF.SettingsPanel = panel
    end
end