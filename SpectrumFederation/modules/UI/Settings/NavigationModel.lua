-- Pure settings navigation helpers. No frames, no C_AddOns, no session storage.
-- Callers pass Registry data (or a test table with the same shape) as arguments.

local _, SF = ...

SF.SettingsNavigationModel = SF.SettingsNavigationModel or {}
local Model = SF.SettingsNavigationModel

local DEFAULT_ORDER = 1000
local RANK_EXACT = 1
local RANK_PREFIX = 2
local RANK_NAME_SUBSTRING = 3
local RANK_DESCRIPTION = 4
local RANK_GROUP = 5

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function Lower(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:lower()
end

function Model.NormalizeQuery(text)
    if type(text) ~= "string" then
        return ""
    end
    return text:lower():gsub("^%s+", ""):gsub("%s+$", "")
end

function Model.LabelOf(item)
    if type(item) ~= "table" then
        return ""
    end
    if IsNonEmptyString(item.navLabel) then
        return item.navLabel
    end
    return item.name or ""
end

-- Optional secondary heading shown under the category title.
-- Pages without contentHeading keep the existing header layout.
function Model.GetPageContentHeading(page)
    if type(page) ~= "table" then
        return nil
    end
    if IsNonEmptyString(page.contentHeading) then
        return page.contentHeading
    end
    return nil
end

local function CompareByOrderLabelId(a, b)
    local oa = (a and a.order) or DEFAULT_ORDER
    local ob = (b and b.order) or DEFAULT_ORDER
    if oa ~= ob then
        return oa < ob
    end
    local la = Lower(Model.LabelOf(a))
    local lb = Lower(Model.LabelOf(b))
    if la ~= lb then
        return la < lb
    end
    return Lower(a and a.id) < Lower(b and b.id)
end

function Model.GetPages(registry)
    if type(registry) ~= "table" then
        return {}
    end
    if type(registry.GetPages) == "function" then
        return registry:GetPages() or {}
    end
    return registry.pages or {}
end

function Model.GetPagesById(registry)
    if type(registry) ~= "table" then
        return {}
    end
    if type(registry.GetPagesById) == "function" then
        return registry:GetPagesById() or {}
    end
    return registry.pagesById or {}
end

function Model.GetCategories(registry)
    if type(registry) ~= "table" then
        return {}
    end
    if type(registry.GetCategories) == "function" then
        return registry:GetCategories() or {}
    end
    return registry.categories or {}
end

function Model.GetCategoriesById(registry)
    if type(registry) ~= "table" then
        return {}
    end
    if type(registry.GetCategoriesById) == "function" then
        return registry:GetCategoriesById() or {}
    end
    return registry.categoriesById or {}
end

function Model.GetPage(registry, pageId)
    if not pageId then
        return nil
    end
    return Model.GetPagesById(registry)[pageId]
end

function Model.GetCategory(registry, categoryId)
    if not categoryId then
        return nil
    end
    local byId = Model.GetCategoriesById(registry)
    if byId[categoryId] then
        return byId[categoryId]
    end
    local pagesById = Model.GetPagesById(registry)
    local page = pagesById[categoryId]
    if page then
        return page
    end
    return nil
end

-- Canonical categoryId: explicit categoryId, else parentId, else the page id.
-- Conflicting categoryId and parentId is a registration error.
function Model.NormalizePageRelationship(page)
    assert(type(page) == "table", "NormalizePageRelationship(page): page must be a table")
    assert(IsNonEmptyString(page.id), "NormalizePageRelationship(page): page.id is required")

    local categoryId = page.categoryId
    local parentId = page.parentId
    local hasCategory = IsNonEmptyString(categoryId)
    local hasParent = IsNonEmptyString(parentId)

    if hasCategory and hasParent and categoryId ~= parentId then
        error(("Page %s has conflicting categoryId (%s) and parentId (%s)"):format(
            page.id, tostring(categoryId), tostring(parentId)))
    end

    if hasCategory then
        return categoryId
    end
    if hasParent then
        return parentId
    end
    return page.id
end

function Model.IsCategoryRoot(page)
    if type(page) ~= "table" or not IsNonEmptyString(page.id) then
        return false
    end
    local categoryId = page.categoryId
    if not IsNonEmptyString(categoryId) then
        categoryId = Model.NormalizePageRelationship(page)
    end
    return categoryId == page.id
end

function Model.IsCategoryEnabled(category)
    if type(category) ~= "table" then
        return true
    end
    if category.enabled == nil then
        return true
    end
    return category.enabled and true or false
end

function Model.IsCategorySelectable(category)
    if type(category) ~= "table" then
        return false
    end
    if category.enablementResolved == false then
        return false
    end
    return Model.IsCategoryEnabled(category)
end

local function PageCategoryId(page)
    if type(page) ~= "table" then
        return nil
    end
    if IsNonEmptyString(page.categoryId) then
        return page.categoryId
    end
    return Model.NormalizePageRelationship(page)
end

function Model.GetContentPages(registry, categoryId)
    local result = {}
    if not IsNonEmptyString(categoryId) then
        return result
    end

    local matching = {}
    local hasNonRoot = false
    for _, page in ipairs(Model.GetPages(registry)) do
        if PageCategoryId(page) == categoryId then
            table.insert(matching, page)
            if page.id ~= categoryId then
                hasNonRoot = true
            end
        end
    end

    for _, page in ipairs(matching) do
        if page.id ~= categoryId or not hasNonRoot then
            table.insert(result, page)
        end
    end

    table.sort(result, CompareByOrderLabelId)
    return result
end

function Model.GetContentPageIds(registry, categoryId)
    local ids = {}
    for _, page in ipairs(Model.GetContentPages(registry, categoryId)) do
        table.insert(ids, page.id)
    end
    return ids
end

function Model.IsContentPage(registry, pageId)
    local page = Model.GetPage(registry, pageId)
    if not page then
        return false
    end
    local categoryId = PageCategoryId(page)
    for _, contentPage in ipairs(Model.GetContentPages(registry, categoryId)) do
        if contentPage.id == pageId then
            return true
        end
    end
    return false
end

function Model.SortedCategories(registry)
    local copy = {}
    for _, category in ipairs(Model.GetCategories(registry)) do
        table.insert(copy, category)
    end
    table.sort(copy, CompareByOrderLabelId)
    return copy
end

function Model.GetDefaultPageId(registry, categoryId)
    local category = Model.GetCategory(registry, categoryId)
    local contentPages = Model.GetContentPages(registry, categoryId)
    if #contentPages == 0 then
        return nil
    end

    local defaultChildId = category and category.defaultChildId
    if IsNonEmptyString(defaultChildId) then
        for _, page in ipairs(contentPages) do
            if page.id == defaultChildId then
                return page.id
            end
        end
    end

    if #contentPages == 1 then
        return contentPages[1].id
    end

    return contentPages[1].id
end

local function CopySelection(categoryId, pageId, changed)
    return {
        categoryId = categoryId,
        pageId = pageId,
        changed = changed and true or false,
    }
end

local function CurrentSelection(session)
    session = session or {}
    return CopySelection(session.currentCategoryId, session.currentPageId, false)
end

function Model.ResolveShowPage(registry, session, id)
    session = session or {}

    if not IsNonEmptyString(id) then
        if session.currentCategoryId then
            return CurrentSelection(session)
        end
        id = "general"
    end

    local pagesById = Model.GetPagesById(registry)
    local categoriesById = Model.GetCategoriesById(registry)
    local page = pagesById[id]
    local category = categoriesById[id]

    if page and Model.IsContentPage(registry, page.id) then
        local categoryId = PageCategoryId(page)
        local targetCategory = Model.GetCategory(registry, categoryId)
        if not Model.IsCategorySelectable(targetCategory) then
            return CurrentSelection(session)
        end
        return CopySelection(categoryId, page.id, true)
    end

    if category or (page and Model.IsCategoryRoot(page)) then
        local categoryId = category and category.id or page.id
        local targetCategory = Model.GetCategory(registry, categoryId)
        if not Model.IsCategorySelectable(targetCategory) then
            return CurrentSelection(session)
        end
        return CopySelection(categoryId, Model.GetDefaultPageId(registry, categoryId), true)
    end

    if session.currentCategoryId then
        return CurrentSelection(session)
    end

    if id ~= "general" then
        return Model.ResolveShowPage(registry, session, "general")
    end

    return CurrentSelection(session)
end

function Model.ResolveSidebarSelect(registry, session, categoryId)
    session = session or {}
    local category = Model.GetCategory(registry, categoryId)
    if not Model.IsCategorySelectable(category) then
        return CurrentSelection(session)
    end

    local lastPageId = session.lastPageByCategory and session.lastPageByCategory[categoryId]
    if lastPageId and Model.IsContentPage(registry, lastPageId) then
        local lastPage = Model.GetPage(registry, lastPageId)
        if lastPage and PageCategoryId(lastPage) == categoryId then
            return CopySelection(categoryId, lastPageId, true)
        end
    end

    return CopySelection(categoryId, Model.GetDefaultPageId(registry, categoryId), true)
end

local function BestFieldRank(query, name, navLabel)
    local fields = { name, navLabel }
    local best
    for i = 1, #fields do
        local value = Lower(fields[i])
        if value ~= "" then
            if value == query then
                return RANK_EXACT
            end
            if value:sub(1, #query) == query then
                if not best or RANK_PREFIX < best then
                    best = RANK_PREFIX
                end
            elseif value:find(query, 1, true) then
                if not best or RANK_NAME_SUBSTRING < best then
                    best = RANK_NAME_SUBSTRING
                end
            end
        end
    end
    return best
end

function Model.RankMatch(item, query)
    query = Model.NormalizeQuery(query)
    if query == "" or type(item) ~= "table" then
        return nil
    end

    local rank = BestFieldRank(query, item.name, item.navLabel)
    if rank then
        return rank
    end

    local description = Lower(item.description)
    if description ~= "" and description:find(query, 1, true) then
        return RANK_DESCRIPTION
    end

    local group = Lower(item.group)
    if group ~= "" and group:find(query, 1, true) then
        return RANK_GROUP
    end

    return nil
end

local function HitSortKey(hit)
    return hit.rank, hit.kindBoost, hit.order or DEFAULT_ORDER, Lower(hit.id)
end

local function CompareHits(a, b)
    local ar, ak, ao, ai = HitSortKey(a)
    local br, bk, bo, bi = HitSortKey(b)
    if ar ~= br then
        return ar < br
    end
    if ak ~= bk then
        return ak < bk
    end
    if ao ~= bo then
        return ao < bo
    end
    return ai < bi
end

function Model.Search(registry, query)
    query = Model.NormalizeQuery(query)
    local hits = {}
    if query == "" then
        return hits
    end

    local matchedCategoryIds = {}

    for _, page in ipairs(Model.GetPages(registry)) do
        if Model.IsContentPage(registry, page.id) then
            local rank = Model.RankMatch(page, query)
            if rank then
                local categoryId = PageCategoryId(page)
                table.insert(hits, {
                    kind = "page",
                    kindBoost = 0,
                    rank = rank,
                    categoryId = categoryId,
                    pageId = page.id,
                    id = page.id,
                    order = page.order,
                })
                matchedCategoryIds[categoryId] = true
            end
        end
    end

    for _, category in ipairs(Model.GetCategories(registry)) do
        local rank = Model.RankMatch(category, query)
        if rank then
            table.insert(hits, {
                kind = "category",
                kindBoost = 1,
                rank = rank,
                categoryId = category.id,
                pageId = nil,
                id = category.id,
                order = category.order,
            })
            matchedCategoryIds[category.id] = true
        end
    end

    table.sort(hits, CompareHits)
    hits.matchedCategoryIds = matchedCategoryIds
    return hits
end

function Model.CategoryMatchesQuery(registry, categoryId, query)
    query = Model.NormalizeQuery(query)
    if query == "" then
        return true
    end

    local category = Model.GetCategory(registry, categoryId)
    if category and Model.RankMatch(category, query) then
        return true
    end

    for _, page in ipairs(Model.GetContentPages(registry, categoryId)) do
        if Model.RankMatch(page, query) then
            return true
        end
    end

    return false
end

function Model.BestMatchingPageInCategory(registry, categoryId, query)
    query = Model.NormalizeQuery(query)
    local contentPages = Model.GetContentPages(registry, categoryId)
    if query == "" or #contentPages == 0 then
        return Model.GetDefaultPageId(registry, categoryId)
    end

    local bestPage
    local bestHit
    for _, page in ipairs(contentPages) do
        local rank = Model.RankMatch(page, query)
        if rank then
            local hit = {
                rank = rank,
                kindBoost = 0,
                order = page.order,
                id = page.id,
            }
            if not bestHit or CompareHits(hit, bestHit) then
                bestHit = hit
                bestPage = page.id
            end
        end
    end

    if bestPage then
        return bestPage
    end

    -- Category-only hits (group/description/name) still open a real page when
    -- the category has content pages. Empty categories keep a nil pageId.
    return Model.GetDefaultPageId(registry, categoryId)
end

function Model.ResolveSearchCategoryClick(registry, session, categoryId, query)
    session = session or {}
    local category = Model.GetCategory(registry, categoryId)
    if not Model.IsCategorySelectable(category) then
        return CurrentSelection(session)
    end

    query = Model.NormalizeQuery(query)
    if query == "" then
        return Model.ResolveSidebarSelect(registry, session, categoryId)
    end

    return CopySelection(categoryId, Model.BestMatchingPageInCategory(registry, categoryId, query), true)
end

function Model.ResolveSearchEnter(registry, session, query)
    session = session or {}
    local hits = Model.Search(registry, query)
    for _, hit in ipairs(hits) do
        local category = Model.GetCategory(registry, hit.categoryId)
        if Model.IsCategorySelectable(category) then
            if hit.kind == "page" then
                return CopySelection(hit.categoryId, hit.pageId, true)
            end
            local pageId = Model.BestMatchingPageInCategory(registry, hit.categoryId, query)
            return CopySelection(hit.categoryId, pageId, true)
        end
    end
    return CurrentSelection(session)
end

function Model.BuildSidebarItems(registry)
    local items = {}
    local currentGroup
    for _, category in ipairs(Model.SortedCategories(registry)) do
        local group = category.group
        if not IsNonEmptyString(group) then
            group = "Optional"
        end
        if group ~= currentGroup then
            currentGroup = group
            table.insert(items, {
                type = "group",
                id = group,
                label = group,
            })
        end
        table.insert(items, {
            type = "category",
            id = category.id,
            label = Model.LabelOf(category),
            enabled = Model.IsCategoryEnabled(category),
            enablementResolved = category.enablementResolved ~= false,
            selectable = Model.IsCategorySelectable(category),
        })
    end
    return items
end

function Model.EffectiveWindowMin(preferredWidth, preferredHeight, availableWidth, availableHeight)
    preferredWidth = tonumber(preferredWidth) or 0
    preferredHeight = tonumber(preferredHeight) or 0
    availableWidth = tonumber(availableWidth) or 0
    availableHeight = tonumber(availableHeight) or 0

    local minWidth = preferredWidth
    local minHeight = preferredHeight
    if availableWidth > 0 then
        minWidth = math.min(preferredWidth, availableWidth)
    end
    if availableHeight > 0 then
        minHeight = math.min(preferredHeight, availableHeight)
    end
    if minWidth < 1 then
        minWidth = 1
    end
    if minHeight < 1 then
        minHeight = 1
    end
    return minWidth, minHeight
end

function Model.StripParentTitlePrefix(title, parentTitle)
    if type(title) ~= "string" or title == "" then
        return title or ""
    end
    if type(parentTitle) ~= "string" or parentTitle == "" then
        parentTitle = "Spectrum Federation"
    end
    local prefix = parentTitle .. ": "
    if Lower(title):sub(1, #prefix) == Lower(prefix) then
        local stripped = title:sub(#prefix + 1)
        if stripped ~= "" then
            return stripped
        end
    end
    return title
end
