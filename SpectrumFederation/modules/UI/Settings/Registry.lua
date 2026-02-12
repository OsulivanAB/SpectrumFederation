-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

-- Feature flag: Set to false to disable Blizzard Settings registration
-- When false, the addon will not appear in WoW Settings > AddOns
-- Pages still register internally for use in standalone window
UI.ENABLE_BLIZZARD_SETTINGS = false

UI.pages = UI.pages or {}
UI.pagesById = UI.pagesById or {}
UI.categoriesByPageId = UI.categoriesByPageId or {}
-- Register a new settings page to be displayed in the settings UI
-- @param page table Page definition table with id, name, and Build function
-- @return nil
-- @error if page is invalid or duplicate id
function UI:RegisterPage(page)
    assert(type(page) == "table", "RegisterPage(page): page must be a table")
    assert(type(page.id) == "string" and page.id ~= "", "Page require a string id")
    assert(type(page.name) == "string" and page.name ~= "", "Page require a display name")
    assert(type(page.Build) == "function", "Page requires Build(self, panel)")
    
    if self.pagesById[page.id] then
        error(("Duplicate settings page id: %s"):format(page.id))
    end

    if SF.Debug then
        SF.Debug:Verbose("UI", "Registering settings page: %s", page.name)
    end

    self.pagesById[page.id] = page
    table.insert(self.pages, page)
end

-- Compare two pages for sorting by order property
-- @param a table First page definition
-- @param b table Second page definition
-- @return boolean True if a should come before b
local function SortPages(a, b)
    return (a.order or 1000) < (b.order or 1000)
end

-- Initialize the settings UI and register all pages with the Blizzard settings panel
-- @return nil
function UI:Init()
    if self.initialized then return end
    self.initialized = true

    if SF.Debug then
        SF.Debug:Info("UI", "Initializing Settings UI")
    end

    -- Skip Blizzard registration if disabled (using standalone window instead)
    if not self.ENABLE_BLIZZARD_SETTINGS then
        if SF.Debug then
            SF.Debug:Info("UI", "Blizzard Settings registration disabled, using standalone window")
        end
        return
    end

    if not Settings or not Settings.RegisterCanvasLayoutCategory then
        if SF.Debug then
            SF.Debug:Warn("UI", "Settings API not available, cannot initialize UI")
        end
        return
    end

    table.sort(self.pages, SortPages)

    for _, page in ipairs(self.pages) do
        if not page.parentId then
            self:_RegisterRootPage(page)
        end
    end

    for _, page in ipairs(self.pages) do
        if page.parentId then
            self:_RegisterSubPage(page)
        end
    end

    if SF.Debug then
        SF.Debug:Info("UI", "Settings UI initialized with %d page(s)", #self.pages)
    end
end

-- Create a frame panel for a settings page with lazy-build and refresh callbacks
-- @param page table Page definition table
-- @return Frame The created panel frame
function UI:_CreatePanelForPage(page)
    local panel = CreateFrame("Frame")
    panel.name = page.name

    panel.OnRefresh = function()
        if not panel.__sfBuilt then
            -- Lazy-build once
            page:Build(panel)
            panel.__sfBuilt = true
        end

        if page.Refresh then
            page:Refresh(panel)
        end
    end

    return panel
end

-- Register a top-level settings page with Blizzard's settings API
-- @param page table Page definition table
-- @return nil
function UI:_RegisterRootPage(page)
    local panel = self:_CreatePanelForPage(page)

    -- Canvas layout registration
    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    category.ID = page.categoryId or (addonName .. "_" .. page.id)

    Settings.RegisterAddOnCategory(category)

    self.categoriesByPageId[page.id] = category
    page.__panel = panel
    page.__category = category

    if SF.SettingsUI and SF.SettingsUI.RegisterPageCategory then
        SF.SettingsUI:RegisterPageCategory(page.id, category)
    end
end

-- Register a sub-page under a parent settings page
-- @param page table Page definition table with parentId field
-- @return nil
function UI:_RegisterSubPage(page)
    local parentCategory = self.categoriesByPageId[page.parentId]
    if not parentCategory then return end

    local panel = self:_CreatePanelForPage(page)

    local subcategory = Settings.RegisterCanvasLayoutSubcategory(parentCategory, panel, page.name)
    subcategory.ID = page.categoryId or (addonName .. "_" .. page.id)

    self.categoriesByPageId[page.id] = subcategory
    page.__panel = panel
    page.__category = subcategory

    if SF.SettingsUI and SF.SettingsUI.RegisterPageCategory then
        SF.SettingsUI:RegisterPageCategory(page.id, subcategory)
    end
end

-- Open the settings panel to a specific page
-- @param pageId string Page ID to open to, defaults to "general"
-- @return nil
function UI:Open(pageId)
    if not Settings or not Settings.OpenToCategory then return end
    local page = self.pagesById[pageId] or self.pagesById["general"]
    if not page or not page.__category then return end

    if SF.Debug then
        SF.Debug:Info("UI", "Opening settings page: %s", tostring(pageId))
    end

    Settings.OpenToCategory(page.__category)
end