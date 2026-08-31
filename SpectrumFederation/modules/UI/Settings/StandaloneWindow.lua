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
    SCREEN_MARGIN = 40,
    RESIZE_HANDLE_SIZE = 16,

    -- Layout
    NAV_WIDTH = 220,
    PADDING = 12,

    -- Navigation elements
    BANNER_HEIGHT = 54,  -- Maintains 4:1 aspect ratio for 512x128 banner texture
    VERSION_HEIGHT = 16,
    SEARCH_LABEL_HEIGHT = 14,
    SEARCH_HEIGHT = 24,
    SEARCH_GAP = 8,
    GROUP_HEADER_HEIGHT = 18,
    GROUP_GAP = 8,
    NAV_BUTTON_HEIGHT = 28,
    NAV_BUTTON_GAP = 6,
    NAV_SPACER_HEIGHT = 12,
    TAB_BAR_HEIGHT = 28,
    TAB_BAR_GAP = 8,

    -- Content area
    CONTENT_PADDING = 12,
    DIVIDER_WIDTH = 1,
    CONTENT_HEADER_HEIGHT = 70,

    -- Colors (RGBA, 0-1 range)
    BG = {0, 0, 0, 0.70},
    BORDER = {0.65, 0.65, 0.65, 0.65},
    DIVIDER = {1, 1, 1, 0.08},
    NAV_SELECTED_BG = {1, 1, 1, 0.08},
    NAV_HOVER_BG = {1, 1, 1, 0.04},
    NAV_TRANSPARENT_BG = {0, 0, 0, 0},
    NAV_DISABLED_TEXT = {0.50, 0.50, 0.50, 0.90},
    NAV_NORMAL_TEXT = {0.84, 0.84, 0.84, 1},
    NAV_SELECTED_TEXT = {1, 1, 1, 1},

    DISABLED_TOOLTIP_TITLE = "Add-on disabled",
    DISABLED_TOOLTIP_TEXT = "This add-on is disabled for this character. Enable it in World of Warcraft's AddOns list. Spectrum Federation cannot enable or disable it from this window.",

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
SettingsWindow.navGroups = {}
SettingsWindow.pagePanels = {}
SettingsWindow.currentCategoryId = nil
SettingsWindow.currentPageId = nil
SettingsWindow.lastPageByCategory = {}

local function Registry()
    return SF.SettingsUI
end

local function Model()
    return SF.SettingsNavigationModel
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

local function GetPage(pageId)
    local ui = Registry()
    return pageId and ui and ui.pagesById and ui.pagesById[pageId] or nil
end

local function GetCategory(categoryId)
    local ui = Registry()
    if ui and ui.GetCategory then
        return ui:GetCategory(categoryId)
    end
    return nil
end

local function GetPageLayout(pageId)
    local page = GetPage(pageId)
    return page and page.layout or nil
end

local function GetSearchQuery()
    local model = Model()
    local text = SettingsWindow.navSearchBox and SettingsWindow.navSearchBox:GetText() or ""
    if model and model.NormalizeQuery then
        return model.NormalizeQuery(text)
    end
    return text:lower():gsub("^%s+", ""):gsub("%s+$", "")
end

function SettingsWindow:Session()
    return {
        currentCategoryId = self.currentCategoryId,
        currentPageId = self.currentPageId,
        lastPageByCategory = self.lastPageByCategory,
    }
end

local function CategoryLabel(category)
    if not category then
        return ""
    end
    return category.navLabel or category.name or ""
end

-- ============================================================
-- Resize
-- ============================================================

function SettingsWindow:GetAvailableSize()
    local width = C.WIDTH
    local height = C.HEIGHT
    if UIParent and UIParent.GetWidth then
        width = UIParent:GetWidth() or width
        height = UIParent:GetHeight() or height
    end
    width = math.max(1, width - (C.SCREEN_MARGIN * 2))
    height = math.max(1, height - (C.SCREEN_MARGIN * 2))
    return width, height
end

function SettingsWindow:_ApplyResizeBounds(minWidth, minHeight, maxWidth, maxHeight)
    local frame = self.frame
    if not frame then return end

    frame:SetResizable(true)
    if maxWidth < minWidth then maxWidth = minWidth end
    if maxHeight < minHeight then maxHeight = minHeight end

    if frame.SetResizeBounds then
        frame:SetResizeBounds(minWidth, minHeight, maxWidth, maxHeight)
    else
        if frame.SetMinResize then frame:SetMinResize(minWidth, minHeight) end
        if frame.SetMaxResize then frame:SetMaxResize(maxWidth, maxHeight) end
    end
end

function SettingsWindow:ApplyPreferredWindowMin(pageId)
    if not self.frame then return end

    local preferredWidth = C.WIDTH
    local preferredHeight = C.HEIGHT
    local layout = GetPageLayout(pageId)
    if layout then
        preferredWidth = layout.windowWidth or preferredWidth
        preferredHeight = layout.windowHeight or preferredHeight
    end

    local availableWidth, availableHeight = self:GetAvailableSize()
    local model = Model()
    local minWidth, minHeight = preferredWidth, preferredHeight
    if model and model.EffectiveWindowMin then
        minWidth, minHeight = model.EffectiveWindowMin(
            preferredWidth, preferredHeight, availableWidth, availableHeight)
    else
        minWidth = math.min(preferredWidth, availableWidth)
        minHeight = math.min(preferredHeight, availableHeight)
    end

    self:_ApplyResizeBounds(minWidth, minHeight, availableWidth, availableHeight)

    local currentWidth = self.frame:GetWidth() or C.WIDTH
    local currentHeight = self.frame:GetHeight() or C.HEIGHT
    local newWidth = currentWidth
    local newHeight = currentHeight
    if currentWidth < minWidth then
        newWidth = minWidth
    end
    if currentHeight < minHeight then
        newHeight = minHeight
    end
    if currentWidth > availableWidth then
        newWidth = availableWidth
    end
    if currentHeight > availableHeight then
        newHeight = availableHeight
    end

    if math.abs(newWidth - currentWidth) > 0.5 or math.abs(newHeight - currentHeight) > 0.5 then
        self.frame:SetSize(newWidth, newHeight)
    end
end

-- ============================================================
-- Navigation Item Registry
-- ============================================================

function SettingsWindow:BuildNavItemsFromRegistry()
    local model = Model()
    local ui = Registry()
    if model and model.BuildSidebarItems and ui then
        self.navItems = model.BuildSidebarItems(ui)
    else
        self.navItems = {}
    end
end

-- ============================================================
-- Navigation UI Creation
-- ============================================================

local function ShowDisabledTooltip(region)
    if not region or not GameTooltip then return end
    GameTooltip:SetOwner(region, "ANCHOR_RIGHT")
    GameTooltip:SetText(C.DISABLED_TOOLTIP_TITLE, 1, 1, 1)
    GameTooltip:AddLine(C.DISABLED_TOOLTIP_TEXT, nil, nil, nil, true)
    GameTooltip:Show()
end

local function HideTooltip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

local function CreateNavButton(parent, label, categoryId, selectable)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(C.NAV_WIDTH - C.PADDING * 2, C.NAV_BUTTON_HEIGHT)
    btn:EnableMouse(true)

    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetColorTexture(unpack(C.NAV_TRANSPARENT_BG))

    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.text:SetPoint("LEFT", btn, "LEFT", 8, 0)
    btn.text:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    btn.text:SetText(label)
    btn.text:SetJustifyH("LEFT")

    btn:SetScript("OnEnter", function(selfBtn)
        if not selectable then
            ShowDisabledTooltip(selfBtn)
            return
        end
        if SettingsWindow.currentCategoryId ~= categoryId then
            selfBtn.bg:SetColorTexture(unpack(C.NAV_HOVER_BG))
        end
    end)

    btn:SetScript("OnLeave", function()
        HideTooltip()
        SettingsWindow:UpdateNavButtonStates()
    end)

    btn:SetScript("OnClick", function()
        if not selectable then
            return
        end
        SettingsWindow:SelectCategory(categoryId)
    end)

    btn.categoryId = categoryId
    btn.selectable = selectable and true or false
    return btn
end

local function CreateGroupHeader(parent, label)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(C.NAV_WIDTH - C.PADDING * 2, C.GROUP_HEADER_HEIGHT)

    frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.text:SetPoint("LEFT", frame, "LEFT", 0, 0)
    frame.text:SetTextColor(0.65, 0.78, 0.95, 0.95)
    frame.text:SetText(label)
    frame.text:SetJustifyH("LEFT")

    return frame
end

function SettingsWindow:ComputeVisibleNavState()
    local query = GetSearchQuery()
    local visibleCategories = {}
    local visibleGroups = {}
    local visibleCount = 0
    local model = Model()
    local ui = Registry()

    for _, item in ipairs(self.navItems or {}) do
        if item.type == "category" then
            local matches = true
            if model and model.CategoryMatchesQuery then
                matches = model.CategoryMatchesQuery(ui, item.id, query)
            end
            if matches then
                visibleCategories[item.id] = true
                visibleCount = visibleCount + 1
                local category = GetCategory(item.id)
                local group = category and category.group or "Optional"
                visibleGroups[group] = true
            end
        end
    end

    return visibleCategories, visibleGroups, visibleCount, query
end

function SettingsWindow:UpdateNavLayout()
    if not self.navPanel then return end
    local yOffset = -C.PADDING
    local visibleCategories, visibleGroups, visibleCount, query = self:ComputeVisibleNavState()

    if self.navBanner then
        self.navBanner:SetPoint("TOP", self.navPanel, "TOP", 0, yOffset)
        yOffset = yOffset - C.BANNER_HEIGHT - 4
    end

    if self.navVersionText then
        self.navVersionText:SetPoint("TOP", self.navPanel, "TOP", 0, yOffset)
        yOffset = yOffset - C.VERSION_HEIGHT
    end

    if self.navSearchLabel then
        yOffset = yOffset - C.SEARCH_GAP
        self.navSearchLabel:SetPoint("TOPLEFT", self.navPanel, "TOPLEFT", C.PADDING, yOffset)
        yOffset = yOffset - C.SEARCH_LABEL_HEIGHT
    end

    if self.navSearchBox then
        self.navSearchBox:ClearAllPoints()
        self.navSearchBox:SetPoint("TOPLEFT", self.navPanel, "TOPLEFT", C.PADDING, yOffset)
        yOffset = yOffset - C.SEARCH_HEIGHT - C.GROUP_GAP
    end

    for _, item in ipairs(self.navItems) do
        if item.type == "group" then
            local groupHeader = self.navGroups[item.id]
            if groupHeader then
                if visibleGroups[item.id] then
                    groupHeader:Show()
                    groupHeader:ClearAllPoints()
                    groupHeader:SetPoint("TOPLEFT", self.navPanel, "TOPLEFT", C.PADDING, yOffset)
                    yOffset = yOffset - C.GROUP_HEADER_HEIGHT - 4
                else
                    groupHeader:Hide()
                end
            end
        elseif item.type == "category" then
            local btn = self.navButtons[item.id]
            if btn then
                if visibleCategories[item.id] then
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

    if self.navEmptyText then
        if query ~= "" and visibleCount == 0 then
            self.navEmptyText:Show()
            self.navEmptyText:ClearAllPoints()
            self.navEmptyText:SetPoint("TOPLEFT", self.navPanel, "TOPLEFT", C.PADDING, yOffset - 6)
        else
            self.navEmptyText:Hide()
        end
    end
end

function SettingsWindow:ClearNavRows()
    for _, btn in pairs(self.navButtons) do
        btn:Hide()
        btn:SetParent(nil)
    end
    for _, header in pairs(self.navGroups) do
        header:Hide()
        header:SetParent(nil)
    end
    self.navButtons = {}
    self.navGroups = {}
end

function SettingsWindow:RebuildNavRows()
    if not self.navPanel then return end
    self:BuildNavItemsFromRegistry()
    self:ClearNavRows()

    for _, item in ipairs(self.navItems) do
        if item.type == "group" then
            local groupHeader = CreateGroupHeader(self.navPanel, item.label)
            self.navGroups[item.id] = groupHeader
        elseif item.type == "category" then
            local btn = CreateNavButton(self.navPanel, item.label, item.id, item.selectable)
            self.navButtons[item.id] = btn
        end
    end

    self:UpdateNavButtonStates()
end

-- Build the navigation panel UI
-- @param navPanel Frame The navigation panel frame
function SettingsWindow:BuildNavPanel(navPanel)
    local yOffset = -C.PADDING

    local banner = navPanel:CreateTexture(nil, "ARTWORK")
    banner:SetPoint("TOP", navPanel, "TOP", 0, yOffset)
    banner:SetSize(C.NAV_WIDTH - C.PADDING * 2, C.BANNER_HEIGHT)
    banner:SetTexture(C.BANNER_TEXTURE)
    self.navBanner = banner
    yOffset = yOffset - C.BANNER_HEIGHT - 4

    local versionText = navPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    versionText:SetPoint("TOP", navPanel, "TOP", 0, yOffset)
    versionText:SetText(GetVersionString())
    versionText:SetTextColor(0.7, 0.7, 0.7, 1)
    self.navVersionText = versionText
    yOffset = yOffset - C.VERSION_HEIGHT

    local searchLabel = navPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetText("Quick Find")
    searchLabel:SetTextColor(0.75, 0.75, 0.75, 0.95)
    self.navSearchLabel = searchLabel
    yOffset = yOffset - C.SEARCH_GAP - C.SEARCH_LABEL_HEIGHT

    local searchBox = CreateFrame("EditBox", nil, navPanel, "InputBoxTemplate")
    searchBox:SetAutoFocus(false)
    searchBox:SetSize(C.NAV_WIDTH - C.PADDING * 2, C.SEARCH_HEIGHT)
    searchBox:SetPoint("TOPLEFT", navPanel, "TOPLEFT", C.PADDING, yOffset)
    searchBox:SetScript("OnTextChanged", function()
        SettingsWindow:UpdateNavLayout()
    end)
    searchBox:SetScript("OnEscapePressed", function(selfEdit)
        selfEdit:SetText("")
        selfEdit:ClearFocus()
        SettingsWindow:UpdateNavLayout()
    end)
    searchBox:SetScript("OnEnterPressed", function(selfEdit)
        selfEdit:ClearFocus()
        SettingsWindow:ActivateSearchEnter()
    end)
    self.navSearchBox = searchBox
    yOffset = yOffset - C.SEARCH_HEIGHT - C.GROUP_GAP

    local emptyText = navPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyText:SetWidth(C.NAV_WIDTH - C.PADDING * 2)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetJustifyV("TOP")
    emptyText:SetText("No matching settings.")
    emptyText:SetTextColor(0.8, 0.8, 0.8, 0.85)
    emptyText:Hide()
    self.navEmptyText = emptyText

    self:RebuildNavRows()
    self:UpdateNavLayout()
end

function SettingsWindow:UpdateNavButtonStates()
    for categoryId, btn in pairs(self.navButtons) do
        local selected = categoryId == self.currentCategoryId
        local selectable = btn.selectable
        if not selectable then
            btn.bg:SetColorTexture(unpack(C.NAV_TRANSPARENT_BG))
            btn.text:SetTextColor(unpack(C.NAV_DISABLED_TEXT))
        elseif selected then
            btn.bg:SetColorTexture(unpack(C.NAV_SELECTED_BG))
            btn.text:SetTextColor(unpack(C.NAV_SELECTED_TEXT))
        else
            btn.bg:SetColorTexture(unpack(C.NAV_TRANSPARENT_BG))
            btn.text:SetTextColor(unpack(C.NAV_NORMAL_TEXT))
        end
    end

    self:UpdateNavLayout()
end

-- ============================================================
-- Content Panel Management
-- ============================================================

function SettingsWindow:GetOrCreatePagePanel(pageId)
    if self.pagePanels[pageId] then
        return self.pagePanels[pageId]
    end

    local page = GetPage(pageId)
    if not page then
        if SF.Debug then
            SF.Debug:Error("UI", "Page not found in registry: %s", tostring(pageId))
        end
        return nil
    end

    local panel = CreateFrame("Frame", nil, self.contentHost)
    panel:SetAllPoints(self.contentHost)
    panel:Hide()
    panel.__sfPageLayout = page.layout or {}

    if type(page.Build) == "function" then
        page:Build(panel)
    end

    self.pagePanels[pageId] = panel

    if SF.Debug then
        SF.Debug:Verbose("UI", "Created panel for page: %s", pageId)
    end

    return panel
end

function SettingsWindow:HidePagePanel(pageId)
    if pageId and self.pagePanels[pageId] then
        self.pagePanels[pageId]:Hide()
    end
end

function SettingsWindow:UpdateContentChrome()
    if not self.contentTitleText then
        return
    end

    local category = GetCategory(self.currentCategoryId)
    local page = GetPage(self.currentPageId)
    local ui = Registry()
    local model = Model()
    local contentPages = {}
    if model and category then
        contentPages = model.GetContentPages(ui, category.id)
    end

    self.contentTitleText:SetText(CategoryLabel(category))

    local description = ""
    if page and page.description and page.description ~= "" then
        description = page.description
    elseif category and category.description then
        description = category.description
    end
    self.contentDescriptionText:SetText(description)

    local showTabs = #contentPages >= 2
    if self.tabBar then
        if showTabs then
            local tabs = {}
            for _, contentPage in ipairs(contentPages) do
                table.insert(tabs, {
                    id = contentPage.id,
                    label = contentPage.navLabel or contentPage.name,
                })
            end
            self.tabBar:Show()
            if self.tabBar.HasSameTabs and self.tabBar:HasSameTabs(tabs) then
                self.tabBar:SetSelected(self.currentPageId)
            else
                self.tabBar:SetTabs(tabs)
                self.tabBar:SetSelected(self.currentPageId)
            end
            self.contentHeader:SetHeight(C.CONTENT_HEADER_HEIGHT + C.TAB_BAR_HEIGHT + C.TAB_BAR_GAP)
        else
            self.tabBar:Hide()
            self.contentHeader:SetHeight(C.CONTENT_HEADER_HEIGHT)
        end
        self.tabBar:Layout()
    end

    local showEmpty = category
        and model
        and model.IsCategorySelectable(category)
        and #contentPages == 0

    if self.emptyState then
        if showEmpty then
            self.emptyState:SetCategory(category)
            self.emptyState:Show()
        else
            self.emptyState:Hide()
        end
    end
end

function SettingsWindow:ApplySelection(selection, opts)
    if not selection or not selection.categoryId then
        return
    end
    opts = opts or {}

    local previousPageId = self.currentPageId
    if previousPageId and previousPageId ~= selection.pageId then
        self:HidePagePanel(previousPageId)
    end

    self.currentCategoryId = selection.categoryId
    self.currentPageId = selection.pageId

    if opts.rememberTab and selection.pageId then
        self.lastPageByCategory[selection.categoryId] = selection.pageId
    end

    self:ApplyPreferredWindowMin(selection.pageId)

    if selection.pageId then
        local panel = self:GetOrCreatePagePanel(selection.pageId)
        if not panel then
            if SF.Debug then
                SF.Debug:Error("UI", "Failed to get panel for page: %s", selection.pageId)
            end
            return
        end
        panel:Show()

        local page = GetPage(selection.pageId)
        if page and type(page.Refresh) == "function" then
            page:Refresh(panel)
        end
    end

    self:UpdateContentChrome()
    self:UpdateNavButtonStates()
end

function SettingsWindow:SelectCategory(categoryId)
    local model = Model()
    local ui = Registry()
    if not model or not ui then return end

    local query = GetSearchQuery()
    local selection
    if query ~= "" then
        selection = model.ResolveSearchCategoryClick(ui, self:Session(), categoryId, query)
    else
        selection = model.ResolveSidebarSelect(ui, self:Session(), categoryId)
    end
    self:ApplySelection(selection, { rememberTab = true })
end

function SettingsWindow:SelectTab(pageId)
    local model = Model()
    local ui = Registry()
    if not model or not ui then return end
    local selection = model.ResolveShowPage(ui, self:Session(), pageId)
    self:ApplySelection(selection, { rememberTab = true })
end

function SettingsWindow:ActivateSearchEnter()
    local model = Model()
    local ui = Registry()
    if not model or not ui then return end
    local selection = model.ResolveSearchEnter(ui, self:Session(), GetSearchQuery())
    self:ApplySelection(selection, { rememberTab = true })
end

-- ============================================================
-- Window Frame Creation
-- ============================================================

function SettingsWindow:CreateWindow()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", C.FRAME_NAME, UIParent, "BackdropTemplate")
    frame:SetSize(C.WIDTH, C.HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:Hide()

    frame:SetBackdrop(C.BACKDROP)
    frame:SetBackdropColor(unpack(C.BG))
    frame:SetBackdropBorderColor(unpack(C.BORDER))

    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(selfFrame) selfFrame:StartMoving() end)
    frame:SetScript("OnDragStop", function(selfFrame) selfFrame:StopMovingOrSizing() end)
    frame:SetClampedToScreen(true)

    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        SettingsWindow:Hide()
    end)

    local navPanel = CreateFrame("Frame", nil, frame)
    navPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", C.PADDING, -C.PADDING)
    navPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", C.PADDING, C.PADDING)
    navPanel:SetWidth(C.NAV_WIDTH)

    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", navPanel, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMLEFT", navPanel, "BOTTOMRIGHT", 0, 0)
    divider:SetWidth(C.DIVIDER_WIDTH)
    divider:SetColorTexture(unpack(C.DIVIDER))

    local contentPanel = CreateFrame("Frame", nil, frame)
    contentPanel:SetPoint("TOPLEFT", divider, "TOPRIGHT", C.CONTENT_PADDING, 0)
    contentPanel:SetPoint("TOP", closeBtn, "BOTTOM", 0, 0)
    contentPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -C.PADDING, C.PADDING)

    local contentHeader = CreateFrame("Frame", nil, contentPanel)
    contentHeader:SetPoint("TOPLEFT", contentPanel, "TOPLEFT", 0, 0)
    contentHeader:SetPoint("TOPRIGHT", contentPanel, "TOPRIGHT", 0, 0)
    contentHeader:SetHeight(C.CONTENT_HEADER_HEIGHT)

    local titleText = contentHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", contentHeader, "TOPLEFT", 0, -4)
    titleText:SetPoint("TOPRIGHT", contentHeader, "TOPRIGHT", 0, -4)
    titleText:SetJustifyH("LEFT")
    titleText:SetTextColor(1, 1, 1, 1)

    local descriptionText = contentHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    descriptionText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -4)
    descriptionText:SetPoint("TOPRIGHT", contentHeader, "TOPRIGHT", 0, -28)
    descriptionText:SetJustifyH("LEFT")
    descriptionText:SetJustifyV("TOP")
    descriptionText:SetTextColor(0.8, 0.8, 0.8, 0.95)

    local tabBar
    if SF.SettingsUI and SF.SettingsUI.TabBar and SF.SettingsUI.TabBar.Create then
        tabBar = SF.SettingsUI.TabBar:Create(contentHeader)
        tabBar:SetPoint("BOTTOMLEFT", contentHeader, "BOTTOMLEFT", 0, 4)
        tabBar:SetPoint("BOTTOMRIGHT", contentHeader, "BOTTOMRIGHT", 0, 4)
        tabBar:SetHeight(C.TAB_BAR_HEIGHT)
        tabBar:SetOnSelect(function(pageId)
            SettingsWindow:SelectTab(pageId)
        end)
        tabBar:Hide()
    end

    local headerDivider = contentHeader:CreateTexture(nil, "ARTWORK")
    headerDivider:SetPoint("BOTTOMLEFT", contentHeader, "BOTTOMLEFT", 0, 0)
    headerDivider:SetPoint("BOTTOMRIGHT", contentHeader, "BOTTOMRIGHT", 0, 0)
    headerDivider:SetHeight(C.DIVIDER_WIDTH)
    headerDivider:SetColorTexture(unpack(C.DIVIDER))

    local contentHost = CreateFrame("Frame", nil, contentPanel)
    contentHost:SetPoint("TOPLEFT", contentHeader, "BOTTOMLEFT", 0, -C.CONTENT_PADDING)
    contentHost:SetPoint("TOPRIGHT", contentHeader, "BOTTOMRIGHT", 0, -C.CONTENT_PADDING)
    contentHost:SetPoint("BOTTOMRIGHT", contentPanel, "BOTTOMRIGHT", 0, 0)

    local emptyState
    if SF.SettingsUI and SF.SettingsUI.EmptyState and SF.SettingsUI.EmptyState.Create then
        emptyState = SF.SettingsUI.EmptyState:Create(contentHost)
        emptyState:SetAllPoints(contentHost)
        emptyState:Hide()
    end

    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(C.RESIZE_HANDLE_SIZE, C.RESIZE_HANDLE_SIZE)
    resize:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        frame:StartSizing("BOTTOMRIGHT")
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        frame:StopMovingOrSizing()
        SettingsWindow:ApplyPreferredWindowMin(SettingsWindow.currentPageId)
    end)

    frame:HookScript("OnSizeChanged", function()
        -- Geometry only. Do not Refresh pages, Store, sync, or inspect.
        SettingsWindow:UpdateNavLayout()
        if SettingsWindow.tabBar and SettingsWindow.tabBar.Layout then
            SettingsWindow.tabBar:Layout()
        end
    end)

    self.frame = frame
    self.navPanel = navPanel
    self.contentPanel = contentPanel
    self.contentHeader = contentHeader
    self.contentHost = contentHost
    self.contentTitleText = titleText
    self.contentDescriptionText = descriptionText
    self.tabBar = tabBar
    self.emptyState = emptyState
    self.resizeHandle = resize

    self:BuildNavPanel(navPanel)
    self:ApplyPreferredWindowMin(nil)

    if SF.Debug then
        SF.Debug:Info("UI", "Standalone Settings Window created")
    end

    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function SettingsWindow:HandleRegistryChanged()
    if not self.navPanel then
        return
    end

    self:RebuildNavRows()

    local model = Model()
    local ui = Registry()
    if not model or not ui or not self.currentCategoryId then
        return
    end

    local category = GetCategory(self.currentCategoryId)
    if not category or not model.IsCategorySelectable(category) then
        self:ApplySelection(model.ResolveShowPage(ui, self:Session(), "general"), { rememberTab = false })
        return
    end

    if self.currentPageId and not model.IsContentPage(ui, self.currentPageId) then
        self:ApplySelection(model.ResolveSidebarSelect(ui, self:Session(), self.currentCategoryId), { rememberTab = true })
        return
    end

    if not self.currentPageId then
        local defaultPageId = model.GetDefaultPageId(ui, self.currentCategoryId)
        if defaultPageId then
            self:ApplySelection({
                categoryId = self.currentCategoryId,
                pageId = defaultPageId,
                changed = true,
            }, { rememberTab = true })
            return
        end
    end

    self:UpdateContentChrome()
    self:UpdateNavButtonStates()
end

function SettingsWindow:RefreshEnablementIfNeeded()
    local ui = Registry()
    if ui and ui.HasUnresolvedSubAddonEnablement and ui.HasUnresolvedSubAddonEnablement(ui) then
        ui:RefreshSubAddonEnablement()
    end
end

function SettingsWindow:Init()
    if self.initialized then return end
    self.initialized = true

    if SF.Debug then
        SF.Debug:Info("UI", "Initializing Standalone Settings Window")
    end

    local ui = Registry()
    if ui and ui.OnRegistryChanged and not self._registryListener then
        ui:OnRegistryChanged(function()
            SettingsWindow:HandleRegistryChanged()
        end)
        self._registryListener = true
    end

    self:BuildNavItemsFromRegistry()
    self:CreateWindow()

    if SF.Debug then
        SF.Debug:Info("UI", "Standalone Settings Window initialized")
    end
end

function SettingsWindow:Show()
    if not self.frame then
        self:Init()
    end

    self:RefreshEnablementIfNeeded()
    self.frame:Show()

    if not self.currentCategoryId then
        self:ShowPage("general")
    end
end

function SettingsWindow:ShowPage(pageId)
    if not self.frame then
        self:Init()
    end

    self:RefreshEnablementIfNeeded()
    self.frame:Show()

    local model = Model()
    local ui = Registry()
    if not model or not ui then
        return
    end

    local selection = model.ResolveShowPage(ui, self:Session(), pageId)
    self:ApplySelection(selection, { rememberTab = false })

    if not self.currentCategoryId then
        self:ApplySelection(model.ResolveShowPage(ui, self:Session(), "general"), { rememberTab = false })
    end
end

function SettingsWindow:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

function SettingsWindow:Toggle()
    if self.frame and self.frame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end
