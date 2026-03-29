-- modules/UI/Settings/StandaloneWindow.lua
-- Standalone Settings Window for Spectrum Federation
-- Replaces Blizzard's built-in AddOn Settings UI with a custom window

local addonName, SF = ...

-- ============================================================
-- Constants
-- ============================================================
local C = {
    -- Frame
    FRAME_NAME = "SF_SettingsWindow",
    WIDTH = 900,
    HEIGHT = 900,
    
    -- Layout
    NAV_WIDTH = 180,
    PADDING = 12,
    
    -- Navigation elements
    BANNER_HEIGHT = 54,  -- Maintains 4:1 aspect ratio for 512x128 banner texture
    VERSION_HEIGHT = 16,
    NAV_BUTTON_HEIGHT = 28,
    NAV_BUTTON_GAP = 6,
    NAV_SPACER_HEIGHT = 12,
    
    -- Content area
    CONTENT_PADDING = 12,
    DIVIDER_WIDTH = 1,
    
    -- Colors (RGBA, 0-1 range)
    BG = {0, 0, 0, 0.70},
    BORDER = {0.65, 0.65, 0.65, 0.65},
    DIVIDER = {1, 1, 1, 0.08},
    NAV_SELECTED_BG = {1, 1, 1, 0.08},
    NAV_HOVER_BG = {1, 1, 1, 0.04},
    NAV_TRANSPARENT_BG = {0, 0, 0, 0},
    
    -- Backdrop settings
    BACKDROP = {
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    },
    
    -- Texture paths
    BANNER_TEXTURE = "Interface\\AddOns\\SpectrumFederation\\media\\Textures\\SpectrumFederationBanner.tga",
}

-- ============================================================
-- Singleton Manager
-- ============================================================
SF.SettingsWindow = SF.SettingsWindow or {}
local SettingsWindow = SF.SettingsWindow

SettingsWindow.frame = nil
SettingsWindow.navItems = {}
SettingsWindow.navButtons = {}
SettingsWindow.pagePanels = {}
SettingsWindow.currentPageId = nil

local function SortPages(a, b)
    return (a.order or 1000) < (b.order or 1000)
end

-- ============================================================
-- Helper Functions
-- ============================================================

-- Get addon version string
-- @return string Version string (e.g., "0.4.0-beta.7")
local function GetVersionString()
    local version = "Unknown"
    if SF and SF.GetAddonVersion then
        version = SF:GetAddonVersion()
    elseif C_AddOns and C_AddOns.GetAddOnMetadata then
        version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "Unknown"
    end
    return "Retail " .. version
end

local function GetPageLayout(pageId)
    local page = pageId and SF.SettingsUI and SF.SettingsUI.pagesById and SF.SettingsUI.pagesById[pageId]
    return page and page.layout or nil
end

-- ============================================================
-- Navigation Item Registry
-- ============================================================

-- Add a spacer to the navigation
-- @param height number Optional height in pixels (default: C.NAV_SPACER_HEIGHT)
function SettingsWindow:AddNavSpacer(height)
    table.insert(self.navItems, {
        type = "spacer",
        height = height or C.NAV_SPACER_HEIGHT
    })
end

-- Add a page button to the navigation
-- @param pageId string Page ID to link to
-- @param label string Display label for the button
function SettingsWindow:AddNavPage(pageId, label)
    table.insert(self.navItems, {
        type = "page",
        id = pageId,
        label = label
    })
end

local function GetRootPageId(pageId)
    local page = pageId and SF.SettingsUI and SF.SettingsUI.pagesById and SF.SettingsUI.pagesById[pageId]
    while page and page.parentId do
        page = SF.SettingsUI.pagesById[page.parentId]
    end
    return page and page.id or pageId
end

local function ResolveSelectablePageId(pageId)
    local page = pageId and SF.SettingsUI and SF.SettingsUI.pagesById and SF.SettingsUI.pagesById[pageId]
    if page and page.defaultChildId and SF.SettingsUI.pagesById[page.defaultChildId] then
        return page.defaultChildId
    end
    return pageId
end

function SettingsWindow:BuildNavItemsFromRegistry()
    self.navItems = {}

    local roots = {}
    local childrenByParent = {}
    for _, page in ipairs(SF.SettingsUI.pages or {}) do
        if page.parentId then
            childrenByParent[page.parentId] = childrenByParent[page.parentId] or {}
            table.insert(childrenByParent[page.parentId], page)
        else
            table.insert(roots, page)
        end
    end

    table.sort(roots, SortPages)
    for _, children in pairs(childrenByParent) do
        table.sort(children, SortPages)
    end

    self:AddNavSpacer()
    for _, page in ipairs(roots) do
        table.insert(self.navItems, {
            type = "page",
            id = page.id,
            label = page.navLabel or page.name,
            depth = 0,
            parentId = nil,
        })

        for _, childPage in ipairs(childrenByParent[page.id] or {}) do
            table.insert(self.navItems, {
                type = "page",
                id = childPage.id,
                label = childPage.navLabel or childPage.name,
                depth = 1,
                parentId = page.id,
            })
        end
    end
end

-- ============================================================
-- Navigation UI Creation
-- ============================================================

-- Create a navigation button
-- @param parent Frame Parent frame
-- @param label string Button label
-- @param pageId string Page ID this button links to
-- @return Button The created button
local function CreateNavButton(parent, label, pageId, depth)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(C.NAV_WIDTH - C.PADDING * 2, C.NAV_BUTTON_HEIGHT)
    
    -- Background highlight
    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetColorTexture(unpack(C.NAV_TRANSPARENT_BG))
    
    -- Label text
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.text:SetPoint("LEFT", btn, "LEFT", 8 + ((depth or 0) * 14), 0)
    btn.text:SetText(label)
    btn.text:SetJustifyH("LEFT")
    
    -- Hover effect
    btn:SetScript("OnEnter", function(self)
        if SettingsWindow.currentPageId ~= pageId then
            self.bg:SetColorTexture(unpack(C.NAV_HOVER_BG))
        end
    end)
    
    btn:SetScript("OnLeave", function(self)
        if SettingsWindow.currentPageId ~= pageId then
            self.bg:SetColorTexture(unpack(C.NAV_TRANSPARENT_BG))
        end
    end)
    
    -- Click handler
    btn:SetScript("OnClick", function()
        SettingsWindow:SelectTab(pageId)
    end)
    
    btn.pageId = pageId
    btn.depth = depth or 0
    return btn
end

function SettingsWindow:UpdateNavLayout()
    if not self.navPanel then return end

    local activeRootId = GetRootPageId(self.currentPageId)
    local yOffset = -C.PADDING

    if self.navBanner then
        self.navBanner:SetPoint("TOP", self.navPanel, "TOP", 0, yOffset)
        yOffset = yOffset - C.BANNER_HEIGHT - 4
    end

    if self.navVersionText then
        self.navVersionText:SetPoint("TOP", self.navPanel, "TOP", 0, yOffset)
        yOffset = yOffset - C.VERSION_HEIGHT
    end

    for _, item in ipairs(self.navItems) do
        if item.type == "spacer" then
            yOffset = yOffset - item.height
        elseif item.type == "page" then
            local btn = self.navButtons[item.id]
            if btn then
                local isVisible = not item.parentId or item.parentId == activeRootId
                if isVisible then
                    btn:Show()
                    btn:ClearAllPoints()
                    btn:SetPoint("TOP", self.navPanel, "TOP", 0, yOffset)
                    yOffset = yOffset - C.NAV_BUTTON_HEIGHT - C.NAV_BUTTON_GAP
                else
                    btn:Hide()
                end
            end
        end
    end
end

-- Build the navigation panel UI
-- @param navPanel Frame The navigation panel frame
function SettingsWindow:BuildNavPanel(navPanel)
    local yOffset = -C.PADDING
    
    -- Banner texture
    local banner = navPanel:CreateTexture(nil, "ARTWORK")
    banner:SetPoint("TOP", navPanel, "TOP", 0, yOffset)
    banner:SetSize(C.NAV_WIDTH - C.PADDING * 2, C.BANNER_HEIGHT)
    banner:SetTexture(C.BANNER_TEXTURE)
    self.navBanner = banner
    yOffset = yOffset - C.BANNER_HEIGHT - 4
    
    -- Version text
    local versionText = navPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    versionText:SetPoint("TOP", navPanel, "TOP", 0, yOffset)
    versionText:SetText(GetVersionString())
    versionText:SetTextColor(0.7, 0.7, 0.7, 1)
    self.navVersionText = versionText
    yOffset = yOffset - C.VERSION_HEIGHT
    
    -- Build navigation items
    for _, item in ipairs(self.navItems) do
        if item.type == "spacer" then
            yOffset = yOffset - item.height
        elseif item.type == "page" then
            local btn = CreateNavButton(navPanel, item.label, item.id, item.depth)
            btn:SetPoint("TOP", navPanel, "TOP", 0, yOffset)
            yOffset = yOffset - C.NAV_BUTTON_HEIGHT - C.NAV_BUTTON_GAP
            
            self.navButtons[item.id] = btn
        end
    end

    self:UpdateNavLayout()
end

-- Update navigation button states to reflect selected tab
-- @param selectedPageId string The currently selected page ID
function SettingsWindow:UpdateNavButtonStates(selectedPageId)
    for pageId, btn in pairs(self.navButtons) do
        if pageId == selectedPageId then
            btn.bg:SetColorTexture(unpack(C.NAV_SELECTED_BG))
            btn.text:SetTextColor(1, 1, 1, 1)
        else
            btn.bg:SetColorTexture(unpack(C.NAV_TRANSPARENT_BG))
            btn.text:SetTextColor(0.8, 0.8, 0.8, 1)
        end
    end

    self:UpdateNavLayout()
end

-- ============================================================
-- Content Panel Management
-- ============================================================

-- Create or get a panel for a page
-- @param pageId string The page ID
-- @return Frame The panel frame for this page
function SettingsWindow:GetOrCreatePagePanel(pageId)
    if self.pagePanels[pageId] then
        return self.pagePanels[pageId]
    end
    
    -- Get the page object from the registry
    local page = SF.SettingsUI.pagesById[pageId]
    if not page then
        if SF.Debug then
            SF.Debug:Error("UI", "Page not found in registry: %s", tostring(pageId))
        end
        return nil
    end
    
    -- Create a new panel for this page
    local panel = CreateFrame("Frame", nil, self.contentHost)
    panel:SetAllPoints(self.contentHost)
    panel:Hide()
    panel.__sfPageLayout = page.layout or {}
    
    -- Build the page UI into this panel (lazy build)
    if type(page.Build) == "function" then
        page:Build(panel)
    end
    
    self.pagePanels[pageId] = panel
    
    if SF.Debug then
        SF.Debug:Verbose("UI", "Created panel for page: %s", pageId)
    end
    
    return panel
end

function SettingsWindow:ApplyPageLayout(pageId)
    if not self.frame then return end

    local layout = GetPageLayout(pageId) or {}
    local width = layout.windowWidth or C.WIDTH
    local height = layout.windowHeight or C.HEIGHT

    if math.abs((self.frame:GetWidth() or 0) - width) > 0.5 or math.abs((self.frame:GetHeight() or 0) - height) > 0.5 then
        self.frame:SetSize(width, height)
    end
end

-- Select and display a tab by page ID
-- @param pageId string The page ID to select
function SettingsWindow:SelectTab(pageId)
    if not pageId then return end

    pageId = ResolveSelectablePageId(pageId)
    
    if SF.Debug then
        SF.Debug:Verbose("UI", "Selecting tab: %s", pageId)
    end
    
    -- Hide current page panel
    if self.currentPageId and self.pagePanels[self.currentPageId] then
        self.pagePanels[self.currentPageId]:Hide()
    end

    self:ApplyPageLayout(pageId)
    
    -- Get or create the new page panel
    local panel = self:GetOrCreatePagePanel(pageId)
    if not panel then
        if SF.Debug then
            SF.Debug:Error("UI", "Failed to get panel for page: %s", pageId)
        end
        return
    end
    
    -- Show the new page panel
    panel:Show()
    
    -- Refresh the page if it has a Refresh method
    local page = SF.SettingsUI.pagesById[pageId]
    if page and type(page.Refresh) == "function" then
        page:Refresh(panel)
    end
    
    -- Update state
    self.currentPageId = pageId
    self:UpdateNavButtonStates(pageId)
end

-- ============================================================
-- Window Frame Creation
-- ============================================================

-- Create the main settings window frame
function SettingsWindow:CreateWindow()
    if self.frame then return self.frame end
    
    -- Main frame
    local frame = CreateFrame("Frame", C.FRAME_NAME, UIParent, "BackdropTemplate")
    frame:SetSize(C.WIDTH, C.HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:Hide()
    
    -- Backdrop
    frame:SetBackdrop(C.BACKDROP)
    frame:SetBackdropColor(unpack(C.BG))
    frame:SetBackdropBorderColor(unpack(C.BORDER))
    
    -- Make movable
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetClampedToScreen(true)
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        SettingsWindow:Hide()
    end)
    
    -- Left navigation panel
    local navPanel = CreateFrame("Frame", nil, frame)
    navPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", C.PADDING, -C.PADDING)
    navPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", C.PADDING, C.PADDING)
    navPanel:SetWidth(C.NAV_WIDTH)
    
    -- Vertical divider
    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", navPanel, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMLEFT", navPanel, "BOTTOMRIGHT", 0, 0)
    divider:SetWidth(C.DIVIDER_WIDTH)
    divider:SetColorTexture(unpack(C.DIVIDER))
    
    -- Right content panel (with scroll frame)
    -- Position below close button to avoid scrollbar overlap
    local contentPanel = CreateFrame("Frame", nil, frame)
    contentPanel:SetPoint("TOPLEFT", divider, "TOPRIGHT", C.CONTENT_PADDING, 0)
    contentPanel:SetPoint("TOP", closeBtn, "BOTTOM", 0, 0)
    contentPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -C.PADDING, C.PADDING)
    
    -- Content host (will contain page panels)
    local contentHost = CreateFrame("Frame", nil, contentPanel)
    contentHost:SetAllPoints(contentPanel)
    
    -- Store references
    self.frame = frame
    self.navPanel = navPanel
    self.contentPanel = contentPanel
    self.contentHost = contentHost
    
    -- Build navigation UI
    self:BuildNavPanel(navPanel)
    
    if SF.Debug then
        SF.Debug:Info("UI", "Standalone Settings Window created")
    end
    
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

-- Initialize the standalone settings window
function SettingsWindow:Init()
    if self.initialized then return end
    self.initialized = true
    
    if SF.Debug then
        SF.Debug:Info("UI", "Initializing Standalone Settings Window")
    end
    
    self:BuildNavItemsFromRegistry()
    
    -- Create the window frame
    self:CreateWindow()
    
    if SF.Debug then
        SF.Debug:Info("UI", "Standalone Settings Window initialized")
    end
end

-- Show the settings window
function SettingsWindow:Show()
    if not self.frame then
        self:Init()
    end
    
    self.frame:Show()
    
    -- Select the first page if none selected
    if not self.currentPageId then
        self:SelectTab("general")
    end
end

-- Show the settings window and open to a specific page
-- @param pageId string The page ID to open to
function SettingsWindow:ShowPage(pageId)
    if not self.frame then
        self:Init()
    end
    
    self.frame:Show()
    
    -- Select the specified page
    if pageId and self.navButtons[pageId] then
        self:SelectTab(pageId)
    elseif not self.currentPageId then
        self:SelectTab("general")
    end
end

-- Hide the settings window
function SettingsWindow:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

-- Toggle the settings window visibility
function SettingsWindow:Toggle()
    if self.frame and self.frame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end
