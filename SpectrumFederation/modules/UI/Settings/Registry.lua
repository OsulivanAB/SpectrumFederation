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
UI.categories = UI.categories or {}
UI.categoriesById = UI.categoriesById or {}
UI.categoriesByPageId = UI.categoriesByPageId or {}
UI._registryCallbacks = UI._registryCallbacks or {}

local DEFAULT_ORDER = 1000

local function Model()
    return SF.SettingsNavigationModel
end

local function DebugInfo(message, ...)
    if SF.Debug then
        SF.Debug:Info("UI", message, ...)
    end
end

local function DebugVerbose(message, ...)
    if SF.Debug then
        SF.Debug:Verbose("UI", message, ...)
    end
end

local function DebugWarn(message, ...)
    if SF.Debug then
        SF.Debug:Warn("UI", message, ...)
    end
end

function UI:GetPages()
    return self.pages
end

function UI:GetPagesById()
    return self.pagesById
end

function UI:GetCategories()
    return self.categories
end

function UI:GetCategoriesById()
    return self.categoriesById
end

function UI:GetCategory(categoryId)
    if not categoryId then
        return nil
    end
    return self.categoriesById[categoryId]
end

function UI:GetPagesForCategory(categoryId)
    local model = Model()
    if model and model.GetContentPages then
        return model.GetContentPages(self, categoryId)
    end
    return {}
end

function UI:OnRegistryChanged(callback)
    if type(callback) == "function" then
        table.insert(self._registryCallbacks, callback)
    end
end

function UI:NotifyRegistryChanged()
    for _, callback in ipairs(self._registryCallbacks) do
        local ok, err = pcall(callback)
        if not ok and SF.Debug then
            SF.Debug:Error("UI", "OnRegistryChanged callback failed: %s", tostring(err))
        end
    end
end

local function UpsertCategoryFromPage(self, page)
    local categoryId = page.categoryId
    local existing = self.categoriesById[categoryId]
    if page.id == categoryId then
        local category = existing or {
            id = categoryId,
            enabled = true,
            enablementResolved = true,
            source = "page",
        }
        category.name = page.name
        category.navLabel = page.navLabel or page.name
        category.group = page.group or category.group or "Optional"
        category.description = page.description
        category.defaultChildId = page.defaultChildId
        category.order = page.order or category.order or DEFAULT_ORDER
        if not existing then
            self.categoriesById[categoryId] = category
            table.insert(self.categories, category)
        end
        return category
    end

    if existing then
        return existing
    end

    local category = {
        id = categoryId,
        name = page.name,
        navLabel = page.navLabel or page.name,
        group = page.group or "Optional",
        description = page.description,
        order = page.order or DEFAULT_ORDER,
        enabled = true,
        enablementResolved = true,
        source = "page",
    }
    self.categoriesById[categoryId] = category
    table.insert(self.categories, category)
    return category
end

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

    local model = Model()
    page.categoryId = model.NormalizePageRelationship(page)

    DebugVerbose("Registering settings page: %s", page.name)

    self.pagesById[page.id] = page
    table.insert(self.pages, page)
    UpsertCategoryFromPage(self, page)
    self:NotifyRegistryChanged()
end

-- Register a top-level settings category that may have zero content pages.
-- Empty categories show the empty-state widget; do not register a synthetic page.
-- @param category table Category definition with id, name, and optional navLabel/group/description/order
-- @return nil
-- @error if category is invalid
function UI:RegisterCategory(category)
    assert(type(category) == "table", "RegisterCategory(category): category must be a table")
    assert(type(category.id) == "string" and category.id ~= "", "Category requires a string id")
    assert(type(category.name) == "string" and category.name ~= "", "Category requires a display name")

    local existing = self.categoriesById[category.id]
    local cat = existing or {
        id = category.id,
        enabled = true,
        enablementResolved = true,
        source = "page",
    }

    cat.name = category.name
    cat.navLabel = category.navLabel or category.name
    cat.group = category.group or cat.group or "Optional"
    cat.description = category.description
    cat.order = category.order or cat.order or DEFAULT_ORDER
    if category.enabled ~= nil then
        cat.enabled = category.enabled and true or false
    end

    if not existing then
        self.categoriesById[category.id] = cat
        table.insert(self.categories, cat)
    end

    DebugVerbose("Registering settings category: %s", cat.name)
    self:NotifyRegistryChanged()
end

-- Compare two pages for sorting by order property
-- @param a table First page definition
-- @param b table Second page definition
-- @return boolean True if a should come before b
local function SortPages(a, b)
    return (a.order or DEFAULT_ORDER) < (b.order or DEFAULT_ORDER)
end

function UI:DiscoverSubAddons(parentAddonName, api)
    local subAddons = SF.SettingsSubAddons
    if not subAddons or not subAddons.EnumerateChildren then
        return
    end

    parentAddonName = parentAddonName or addonName
    local children = subAddons.EnumerateChildren(parentAddonName, api)
    local changed = false

    for _, child in ipairs(children) do
        local categoryId = child.addonName
        local existing = self.categoriesById[categoryId]
        if not existing then
            local category = {
                id = categoryId,
                name = child.navLabel or child.title or categoryId,
                navLabel = child.navLabel or child.title or categoryId,
                group = "Optional",
                description = child.notes,
                order = DEFAULT_ORDER,
                enabled = false,
                enablementResolved = false,
                addonName = child.addonName,
                source = "addon",
            }
            self.categoriesById[categoryId] = category
            table.insert(self.categories, category)
            changed = true
        else
            if child.navLabel and existing.source == "addon" then
                existing.name = child.navLabel
                existing.navLabel = child.navLabel
            end
            if child.notes and existing.source == "addon" then
                existing.description = child.notes
            end
            existing.addonName = existing.addonName or child.addonName
        end
    end

    if changed then
        self:NotifyRegistryChanged()
    end
end

function UI:RefreshSubAddonEnablement(api)
    local subAddons = SF.SettingsSubAddons
    if not subAddons or not subAddons.IsEnabledForCharacter then
        return
    end

    local changed = false
    for _, category in ipairs(self.categories) do
        if category.addonName then
            local enabled = subAddons.IsEnabledForCharacter(category.addonName, api)
            if enabled ~= nil then
                if category.enabled ~= enabled or category.enablementResolved ~= true then
                    category.enabled = enabled and true or false
                    category.enablementResolved = true
                    changed = true
                end
            end
        end
    end

    if changed then
        self:NotifyRegistryChanged()
    end
end

function UI:HasUnresolvedSubAddonEnablement()
    for _, category in ipairs(self.categories) do
        if category.addonName and category.enablementResolved ~= true then
            return true
        end
    end
    return false
end

-- Initialize the settings UI and register all pages with the Blizzard settings panel
-- @return nil
function UI:Init()
    if self.initialized then return end
    self.initialized = true

    DebugInfo("Initializing Settings UI")

    self:DiscoverSubAddons()

    if not self._enablementFrame then
        local eventFrame = CreateFrame("Frame")
        eventFrame:RegisterEvent("PLAYER_LOGIN")
        eventFrame:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_LOGIN" then
                UI:RefreshSubAddonEnablement()
            end
        end)
        self._enablementFrame = eventFrame
    end

    self:RefreshSubAddonEnablement()

    -- Skip Blizzard registration if disabled (using standalone window instead)
    if not self.ENABLE_BLIZZARD_SETTINGS then
        DebugInfo("Blizzard Settings registration disabled, using standalone window")
        return
    end

    if not Settings or not Settings.RegisterCanvasLayoutCategory then
        DebugWarn("Settings API not available, cannot initialize UI")
        return
    end

    table.sort(self.pages, SortPages)

    for _, page in ipairs(self.pages) do
        if not page.parentId and page.categoryId == page.id then
            self:_RegisterRootPage(page)
        end
    end

    for _, page in ipairs(self.pages) do
        if page.parentId or (page.categoryId and page.categoryId ~= page.id) then
            self:_RegisterSubPage(page)
        end
    end

    DebugInfo("Settings UI initialized with %d page(s)", #self.pages)
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
    local parentId = page.parentId or page.categoryId
    local parentCategory = self.categoriesByPageId[parentId]
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

    DebugInfo("Opening settings page: %s", tostring(pageId))

    Settings.OpenToCategory(page.__category)
end
