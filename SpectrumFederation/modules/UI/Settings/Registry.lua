-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI.pages = UI.pages or {}
UI.pagesById = UI.pagesById or {}
UI.categoriesByPageId = UI.categoriesByPageId or {}

function UI:RegisterPage(page)
    assert(type(page) == "table", "RegisterPage(page): page must be a table")
    assert(type(page.id) == "string" and page.id ~= "", "Page require a string id")
    assert(type(page.name) == "string" and page.name ~= "", "Page require a display name")
    assert(type(page.Build) == "function", "Page requires Build(self, panel)")
    
    if self.pagesById[page.id] then
        error(("Duplicate settings page id: %s"):format(page.id))
    end

    self.pagesById[page.id] = page
    table.insert(self.pages, page)
end

local function SortPages(a, b)
    return (a.order or 1000) < (b.order or 1000)
end

function UI:Init()
    if self.initialized then return end
    self.initialized = true

    if not Settings or not Settings.RegisterCanvasLayoutCategory then
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
end

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

function UI:_RegisterRootPage(page)
    local panel = self:_CreatePanelForPage(page)

    -- Canvas layout registration
    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    category.ID = page.categoryId or (addonName .. "_" .. page.id)

    Settings.RegisterAddOnCategory(category)

    self.categoriesByPageId[page.id] = category
    page.__panel = panel
    page.__category = category
end

function UI:_RegisterSubPage(page)
    local parentCategory = self.categoriesByPageId[page.parentId]
    if not parentCategory then return end

    local panel = self:_CreatePanelForPage(page)

    local subcategory = Settings.RegisterCanvasLayoutSubcategory(parentCategory, panel, page.name)
    subcategory.ID = page.categoryId or (addonName .. "_" .. page.id)

    self.categoriesByPageId[page.id] = subcategory
    page.__panel = panel
    page.__category = subcategory
end

-- NOTE: Opening subcategories directly may not work reliably
function UI:Open(pageId)
    if not Settings or not Settings.OpenToCategory then return end
    local page = self.pagesById[pageId] or self.pagesById["main"]
    if not page or not page.__category then return end

    Settings.OpenToCategory(page.__category)
end