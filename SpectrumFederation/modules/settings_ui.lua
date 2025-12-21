-- Grab the namespace
local addonName, SF = ...

-- Main Settings UI - Creates the base panel with banner and loads sub-sections
function SF:CreateSettingsUI()
    -- Create the canvas for the main panel frame
    local panel = CreateFrame("Frame", nil, UIParent)

    -- Banner
    local banner = panel:CreateTexture(nil, "ARTWORK")
    banner:SetTexture("Interface\\Addons\\SpectrumFederation\\media\\Textures\\SpectrumFederationBanner.tga")
    banner:SetPoint("TOP", panel, "TOP", 0, -10)
    
    -- Original banner dimensions for aspect ratio calculation
    local bannerOriginalWidth = 512
    local bannerOriginalHeight = 128
    local bannerAspectRatio = bannerOriginalWidth / bannerOriginalHeight
    
    -- Set initial size (will be updated dynamically)
    banner:SetSize(600, 600 / bannerAspectRatio)
    
    -- Function to update banner size based on panel width
    local function UpdateBannerSize()
        local panelWidth = panel:GetWidth()
        if panelWidth and panelWidth > 0 then
            local newBannerWidth = panelWidth * 0.90  -- 90% of panel width
            local newBannerHeight = newBannerWidth / bannerAspectRatio  -- Maintain aspect ratio
            banner:SetSize(newBannerWidth, newBannerHeight)
        end
    end
    
    -- Update banner size when panel size changes
    panel:SetScript("OnSizeChanged", function(self, width, height)
        UpdateBannerSize()
    end)
    
    -- Initial update when shown
    C_Timer.After(0.1, function()
        if panel:IsShown() then
            UpdateBannerSize()
        end
    end)

    -- Create sections (add more here as needed)
    SF:CreateLootHelperSection(panel, banner)

    -- Register the panel in the Settings UI
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