-- Behavioral tests for production NavigationModel.lua (and Registry/SubAddons helpers).
-- Run from the repository root: lua5.1 tests/lua/settings_navigation_tests.lua

local function repoPath(relative)
    return relative
end

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. message .. "\n")
end

local function assertTrue(cond, message)
    if cond then
        pass(message)
    else
        fail(message)
    end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assertDeepEq(actual, expected, message)
    if type(actual) ~= "table" or type(expected) ~= "table" then
        assertEq(actual, expected, message)
        return
    end
    if #actual ~= #expected then
        fail(string.format("%s (list length expected %s, got %s)", message, tostring(#expected), tostring(#actual)))
        return
    end
    for i = 1, #expected do
        if actual[i] ~= expected[i] then
            fail(string.format("%s (index %d expected %s, got %s)", message, i, tostring(expected[i]), tostring(actual[i])))
            return
        end
    end
    pass(message)
end

local function idsOf(pages)
    local ids = {}
    for i = 1, #pages do
        ids[i] = pages[i].id
    end
    return ids
end

local SF = {}
local navChunk = assert(loadfile(repoPath("SpectrumFederation/modules/UI/Settings/NavigationModel.lua")))
navChunk("SpectrumFederation", SF)
local subChunk = assert(loadfile(repoPath("SpectrumFederation/modules/UI/Settings/SubAddons.lua")))
subChunk("SpectrumFederation", SF)
local regChunk = assert(loadfile(repoPath("SpectrumFederation/modules/UI/Settings/Registry.lua")))
regChunk("SpectrumFederation", SF)

local Model = SF.SettingsNavigationModel
local SubAddons = SF.SettingsSubAddons
local UI = SF.SettingsUI

local function page(spec)
    spec.Build = spec.Build or function() end
    return spec
end

local function productionFixture()
    local pages = {
        page({
            id = "general",
            name = "General",
            navLabel = "General",
            group = "Core",
            description = "Customize the addon's overall look and feel.",
            order = 10,
        }),
        page({
            id = "lootHelper",
            name = "Loot Helper",
            navLabel = "Loot Helper",
            group = "Loot Tools",
            description = "Configure loot profiles, sessions, raid check tools, and admin workflows.",
            defaultChildId = "lootHelperGeneral",
            order = 20,
        }),
        page({
            id = "lootHelperGeneral",
            parentId = "lootHelper",
            name = "General Settings",
            navLabel = "General",
            description = "Set the default behavior used across Loot Helper features.",
            order = 20.5,
        }),
        page({
            id = "lootHelperProfile",
            parentId = "lootHelper",
            name = "Profile Settings",
            navLabel = "Profile",
            description = "Create, choose, and manage the active loot profile.",
            order = 21,
        }),
        page({
            id = "lootHelperSession",
            parentId = "lootHelper",
            name = "Session Settings",
            navLabel = "Session",
            description = "Control sync sessions, member handling, and live raid activity.",
            order = 22,
        }),
        page({
            id = "lootHelperEquipment",
            parentId = "lootHelper",
            name = "Raid Check Equipment",
            navLabel = "Equipment",
            description = "Inspect raid equipment and gem state from the Raid Check tools.",
            order = 22.5,
            layout = { windowWidth = 1280, disablePageScroll = true },
        }),
        page({
            id = "lootHelperAdmin",
            parentId = "lootHelper",
            name = "Admin Settings",
            navLabel = "Admin",
            description = "Manage admin-only tools and profile permissions.",
            order = 23,
        }),
        page({
            id = "lootLogs",
            name = "Loot Logs",
            navLabel = "Loot Logs",
            group = "Loot Tools",
            description = "Review loot history, filter activity, and audit profile changes.",
            order = 30,
            layout = { windowWidth = 1350, disablePageScroll = true },
        }),
        page({
            id = "debugging",
            name = "Debugging",
            navLabel = "Debugging",
            group = "Advanced",
            description = "Enable diagnostics and review live addon logs for troubleshooting.",
            order = 40,
        }),
        page({
            id = "widgets",
            name = "Widgets",
            navLabel = "Widgets",
            group = "Optional",
            description = "Generic second category used to prove the root-with-children rule.",
            defaultChildId = "widgetsAlpha",
            order = 50,
        }),
        page({
            id = "widgetsAlpha",
            parentId = "widgets",
            name = "Alpha Tools",
            navLabel = "Alpha",
            description = "First child of the generic widgets category.",
            order = 51,
        }),
        page({
            id = "widgetsBeta",
            categoryId = "widgets",
            name = "Beta Tools",
            navLabel = "Beta",
            description = "Second child of the generic widgets category.",
            order = 52,
        }),
    }

    local pagesById = {}
    local categories = {}
    local categoriesById = {}

    for _, item in ipairs(pages) do
        item.categoryId = Model.NormalizePageRelationship(item)
        pagesById[item.id] = item
    end

    local function upsertCategory(item)
        local categoryId = item.categoryId
        local existing = categoriesById[categoryId]
        if item.id == categoryId then
            local cat = existing or {
                id = categoryId,
                enabled = true,
                enablementResolved = true,
            }
            cat.name = item.name
            cat.navLabel = item.navLabel or item.name
            cat.group = item.group or cat.group or "Optional"
            cat.description = item.description
            cat.defaultChildId = item.defaultChildId
            cat.order = item.order or 1000
            if not existing then
                categoriesById[categoryId] = cat
                table.insert(categories, cat)
            end
        elseif not categoriesById[categoryId] then
            local cat = {
                id = categoryId,
                name = item.name,
                navLabel = item.navLabel or item.name,
                group = item.group or "Optional",
                description = item.description,
                order = item.order or 1000,
                enabled = true,
                enablementResolved = true,
            }
            categoriesById[categoryId] = cat
            table.insert(categories, cat)
        end
    end

    for _, item in ipairs(pages) do
        upsertCategory(item)
    end

    table.insert(categories, {
        id = "SpectrumFederation_CursedSurgeTracker",
        name = "Cursed Surge Tracker",
        navLabel = "Cursed Surge Tracker",
        group = "Optional",
        description = "Shows Curse Surge locations and countdowns on The Coiled Isle map.",
        order = 1000,
        enabled = false,
        enablementResolved = true,
        addonName = "SpectrumFederation_CursedSurgeTracker",
    })
    categoriesById.SpectrumFederation_CursedSurgeTracker = categories[#categories]

    table.insert(categories, {
        id = "emptyAddon",
        name = "Empty Addon",
        navLabel = "Empty Addon",
        group = "Optional",
        description = "An enabled category with no settings pages.",
        order = 1001,
        enabled = true,
        enablementResolved = true,
        addonName = "emptyAddon",
    })
    categoriesById.emptyAddon = categories[#categories]

    return {
        pages = pages,
        pagesById = pagesById,
        categories = categories,
        categoriesById = categoriesById,
    }
end

local registry = productionFixture()

-- Content page lists
assertDeepEq(
    idsOf(Model.GetContentPages(registry, "lootHelper")),
    { "lootHelperGeneral", "lootHelperProfile", "lootHelperSession", "lootHelperEquipment", "lootHelperAdmin" },
    "Loot Helper has exactly five content pages"
)
assertTrue(not Model.IsContentPage(registry, "lootHelper"), "lootHelper root is not a content page")
assertDeepEq(
    idsOf(Model.GetContentPages(registry, "widgets")),
    { "widgetsAlpha", "widgetsBeta" },
    "generic root-with-children excludes the root page"
)
assertDeepEq(
    idsOf(Model.GetContentPages(registry, "general")),
    { "general" },
    "root without children is itself the content page"
)
assertEq(#Model.GetContentPages(registry, "emptyAddon"), 0, "enabled empty category has zero content pages")
assertEq(#Model.GetContentPages(registry, "SpectrumFederation_CursedSurgeTracker"), 0, "disabled discovered category has zero content pages")
assertEq(#Model.GetContentPages(registry, "lootHelper") >= 2 and 2 or 0, 2, "Loot Helper is a 2+ page category")
assertEq(#Model.GetContentPages(registry, "debugging"), 1, "Debugging is a single-page category")

-- categoryId vs parentId
local okConflict, errConflict = pcall(function()
    Model.NormalizePageRelationship({
        id = "broken",
        categoryId = "one",
        parentId = "two",
        name = "Broken",
    })
end)
assertTrue(not okConflict, "conflicting categoryId and parentId errors")
assertTrue(type(errConflict) == "string" and errConflict:find("conflicting", 1, true) ~= nil, "conflict error mentions conflicting")
assertEq(
    Model.NormalizePageRelationship({ id = "same", categoryId = "root", parentId = "root" }),
    "root",
    "matching categoryId and parentId are accepted"
)
assertEq(
    Model.NormalizePageRelationship({ id = "child", parentId = "lootHelper" }),
    "lootHelper",
    "legacy parentId becomes categoryId"
)
assertEq(
    Model.NormalizePageRelationship({ id = "general" }),
    "general",
    "root page id is the categoryId"
)

-- ShowPage ignores last-tab
local session = {
    currentCategoryId = "lootHelper",
    currentPageId = "lootHelperEquipment",
    lastPageByCategory = { lootHelper = "lootHelperEquipment" },
}
local showRoot = Model.ResolveShowPage(registry, session, "lootHelper")
assertEq(showRoot.categoryId, "lootHelper", "ShowPage(lootHelper) stays on Loot Helper")
assertEq(showRoot.pageId, "lootHelperGeneral", "ShowPage(lootHelper) opens General, not last-tab")
local showEquip = Model.ResolveShowPage(registry, session, "lootHelperEquipment")
assertEq(showEquip.pageId, "lootHelperEquipment", "ShowPage(lootHelperEquipment) opens Equipment")
local showDebug = Model.ResolveShowPage(registry, session, "debugging")
assertEq(showDebug.pageId, "debugging", "ShowPage(debugging) opens Debugging")

-- Sidebar last-tab vs ShowPage
local sidebar = Model.ResolveSidebarSelect(registry, session, "lootHelper")
assertEq(sidebar.pageId, "lootHelperEquipment", "sidebar click restores last-tab Equipment")
local sidebarFresh = Model.ResolveSidebarSelect(registry, { lastPageByCategory = {} }, "lootHelper")
assertEq(sidebarFresh.pageId, "lootHelperGeneral", "sidebar without last-tab uses defaultChildId")

-- Disabled selection rejected
local disabled = Model.ResolveShowPage(registry, session, "SpectrumFederation_CursedSurgeTracker")
assertEq(disabled.changed, false, "ShowPage of a disabled category is rejected")
assertEq(disabled.pageId, "lootHelperEquipment", "disabled ShowPage keeps the current page")
local disabledSidebar = Model.ResolveSidebarSelect(registry, session, "SpectrumFederation_CursedSurgeTracker")
assertEq(disabledSidebar.changed, false, "disabled sidebar click is rejected")
local emptySelect = Model.ResolveSidebarSelect(registry, {}, "emptyAddon")
assertEq(emptySelect.categoryId, "emptyAddon", "enabled empty category can be selected")
assertEq(emptySelect.pageId, nil, "enabled empty category has a nil page id")

-- Unknown id fallback
local unknownWithSession = Model.ResolveShowPage(registry, session, "noSuchPage")
assertEq(unknownWithSession.changed, false, "unknown id is a no-op when a page is selected")
local unknownFirstOpen = Model.ResolveShowPage(registry, {}, "noSuchPage")
assertEq(unknownFirstOpen.pageId, "general", "unknown id on first open falls back to general")
local firstOpen = Model.ResolveShowPage(registry, {}, nil)
assertEq(firstOpen.pageId, "general", "first open with no id is general")

-- Search fields
assertTrue(Model.CategoryMatchesQuery(registry, "lootHelper", "Loot Tools"), "search matches category group")
assertTrue(Model.CategoryMatchesQuery(registry, "lootHelper", "raid check tools"), "search matches category description")
assertTrue(Model.CategoryMatchesQuery(registry, "lootHelper", "Equipment"), "search matches content-page navLabel")
assertTrue(Model.CategoryMatchesQuery(registry, "debugging", "Debugging"), "search matches category name")
assertTrue(not Model.CategoryMatchesQuery(registry, "debugging", "Equipment"), "unrelated category does not match Equipment")

local equipmentHits = Model.Search(registry, "Equipment")
assertTrue(#equipmentHits > 0, "Equipment query returns hits")
assertEq(equipmentHits[1].pageId, "lootHelperEquipment", "Equipment query ranks the Equipment page first")
assertEq(equipmentHits[1].categoryId, "lootHelper", "Equipment query stays in Loot Helper")

local searchClick = Model.ResolveSearchCategoryClick(registry, session, "lootHelper", "Equipment")
assertEq(searchClick.pageId, "lootHelperEquipment", "search category click opens the matching tab, not last-tab")
local groupClick = Model.ResolveSearchCategoryClick(registry, session, "lootHelper", "Loot Tools")
assertEq(groupClick.pageId, "lootHelperGeneral", "category-only search click opens the default page, not a blank category")
local descClick = Model.ResolveSearchCategoryClick(registry, session, "lootHelper", "admin workflows")
assertEq(descClick.pageId, "lootHelperGeneral", "description-only search click opens the default Loot Helper page")
local emptySearchClick = Model.ResolveSearchCategoryClick(registry, {}, "emptyAddon", "Empty Addon")
assertEq(emptySearchClick.categoryId, "emptyAddon", "empty category remains selectable from search")
assertEq(emptySearchClick.pageId, nil, "empty category search still has no content page")
local searchEnterDisabled = Model.ResolveSearchEnter(registry, session, "Cursed Surge")
assertEq(searchEnterDisabled.changed, false, "Enter does not select a disabled category")
local searchEnter = Model.ResolveSearchEnter(registry, session, "Debugging")
assertEq(searchEnter.pageId, "debugging", "Enter jumps to the best enabled match")

-- Ranking / tie-break is not pairs order
local reverseRegistry = {
    pages = {},
    pagesById = {},
    categories = {},
    categoriesById = {},
}
for i = #registry.pages, 1, -1 do
    table.insert(reverseRegistry.pages, registry.pages[i])
end
for id, item in pairs(registry.pagesById) do
    reverseRegistry.pagesById[id] = item
end
for i = #registry.categories, 1, -1 do
    table.insert(reverseRegistry.categories, registry.categories[i])
end
for id, item in pairs(registry.categoriesById) do
    reverseRegistry.categoriesById[id] = item
end
assertDeepEq(
    idsOf(Model.GetContentPages(reverseRegistry, "lootHelper")),
    { "lootHelperGeneral", "lootHelperProfile", "lootHelperSession", "lootHelperEquipment", "lootHelperAdmin" },
    "content page order does not follow pairs/insertion order"
)
local sorted = Model.SortedCategories(reverseRegistry)
assertEq(sorted[1].id, "general", "category sort starts with General")
assertEq(sorted[2].id, "lootHelper", "category sort keeps Loot Helper after General")

local sidebarItems = Model.BuildSidebarItems(registry)
assertEq(sidebarItems[1].type, "group", "sidebar starts with a group header")
assertEq(sidebarItems[1].label, "Core", "first group is Core")
local groups = {}
for _, item in ipairs(sidebarItems) do
    if item.type == "group" then
        table.insert(groups, item.label)
    end
end
assertDeepEq(groups, { "Core", "Loot Tools", "Advanced", "Optional" }, "group headers follow sorted category appearance")

-- Title prefix strip
assertEq(
    Model.StripParentTitlePrefix("Spectrum Federation: Cursed Surge Tracker", "Spectrum Federation"),
    "Cursed Surge Tracker",
    "Title prefix is stripped"
)
assertEq(
    Model.StripParentTitlePrefix("Cursed Surge Tracker", "Spectrum Federation"),
    "Cursed Surge Tracker",
    "Title without prefix is unchanged"
)
assertEq(
    SubAddons.StripParentTitlePrefix("Spectrum Federation: Cursed Surge Tracker", "Spectrum Federation"),
    "Cursed Surge Tracker",
    "SubAddons uses the same prefix helper"
)

-- Effective window min
local minW, minH = Model.EffectiveWindowMin(1350, 900, 1200, 800)
assertEq(minW, 1200, "effective min width is min(preferred, available)")
assertEq(minH, 800, "effective min height is min(preferred, available)")
local minW2, minH2 = Model.EffectiveWindowMin(900, 900, 1920, 1080)
assertEq(minW2, 900, "effective min keeps preferred when the screen is larger")
assertEq(minH2, 900, "effective min height keeps preferred when the screen is larger")

-- SubAddons enumeration with injected fakes
local fakeAddons = {
    { name = "SpectrumFederation", title = "Spectrum Federation", notes = "parent" },
    { name = "Unrelated", title = "Unrelated", notes = "nope", parent = "SomeoneElse" },
    {
        name = "SpectrumFederation_CursedSurgeTracker",
        title = "Spectrum Federation: Cursed Surge Tracker",
        notes = "Shows Curse Surge locations and countdowns on The Coiled Isle map.",
        parent = "SpectrumFederation",
    },
}
local enumerated = SubAddons.EnumerateChildren("SpectrumFederation", {
    GetNumAddOns = function()
        return #fakeAddons
    end,
    GetAddOnName = function(index)
        return fakeAddons[index].name
    end,
    GetAddOnMetadata = function(name, key)
        for i = 1, #fakeAddons do
            local addon = fakeAddons[i]
            if addon.name:lower() == tostring(name):lower() then
                if key == "Title" then
                    return addon.title
                end
                if key == "Notes" then
                    return addon.notes
                end
                if key == "X-SpectrumFederation-Parent" then
                    return addon.parent
                end
            end
        end
        return nil
    end,
})
assertEq(#enumerated, 1, "enumerator finds only addons with the parent metadata key")
assertEq(enumerated[1].addonName, "SpectrumFederation_CursedSurgeTracker", "enumerator uses the addon folder name")
assertEq(enumerated[1].navLabel, "Cursed Surge Tracker", "enumerator strips the parent title prefix")

local enabled = SubAddons.IsEnabledForCharacter("SpectrumFederation_CursedSurgeTracker", {
    character = "Player-1",
    GetAddOnEnableState = function(_, character)
        assertTrue(character == "Player-1", "enablement query receives the character identity")
        return 2
    end,
    AddOnEnableState = { All = 2, Some = 1, None = 0 },
})
assertEq(enabled, true, "enablement All is treated as enabled")
local unresolved = SubAddons.IsEnabledForCharacter("SpectrumFederation_CursedSurgeTracker", {
    UnitGUID = function()
        return nil
    end,
    UnitName = function()
        return nil
    end,
    GetAddOnEnableState = function()
        fail("enablement must not be queried without a character identity")
        return 2
    end,
})
assertEq(unresolved, nil, "missing GUID leaves enablement unresolved")

-- Registry: duplicate ids, conflict, root-with-children, notify
UI.pages = {}
UI.pagesById = {}
UI.categories = {}
UI.categoriesById = {}
UI._registryCallbacks = {}

local notified = 0
UI:OnRegistryChanged(function()
    notified = notified + 1
end)

UI:RegisterPage(page({
    id = "lootHelper",
    name = "Loot Helper",
    navLabel = "Loot Helper",
    group = "Loot Tools",
    defaultChildId = "lootHelperGeneral",
    order = 20,
}))
UI:RegisterPage(page({
    id = "lootHelperGeneral",
    parentId = "lootHelper",
    name = "General Settings",
    navLabel = "General",
    order = 20.5,
}))
UI:RegisterPage(page({
    id = "lootHelperProfile",
    parentId = "lootHelper",
    name = "Profile Settings",
    navLabel = "Profile",
    order = 21,
}))
assertDeepEq(
    idsOf(UI:GetPagesForCategory("lootHelper")),
    { "lootHelperGeneral", "lootHelperProfile" },
    "Registry GetPagesForCategory excludes the lootHelper root"
)
assertTrue(notified >= 3, "RegisterPage notifies listeners")

local dupOk = pcall(function()
    UI:RegisterPage(page({ id = "lootHelper", name = "Loot Helper" }))
end)
assertTrue(not dupOk, "duplicate page ids error")

local conflictOk = pcall(function()
    UI:RegisterPage(page({
        id = "brokenChild",
        name = "Broken",
        categoryId = "one",
        parentId = "two",
    }))
end)
assertTrue(not conflictOk, "Registry rejects conflicting categoryId and parentId")

UI:DiscoverSubAddons("SpectrumFederation", {
    GetNumAddOns = function()
        return #fakeAddons
    end,
    GetAddOnName = function(index)
        return fakeAddons[index].name
    end,
    GetAddOnMetadata = function(name, key)
        for i = 1, #fakeAddons do
            local addon = fakeAddons[i]
            if addon.name:lower() == tostring(name):lower() then
                if key == "Title" then
                    return addon.title
                end
                if key == "Notes" then
                    return addon.notes
                end
                if key == "X-SpectrumFederation-Parent" then
                    return addon.parent
                end
            end
        end
        return nil
    end,
})
local discovered = UI:GetCategory("SpectrumFederation_CursedSurgeTracker")
assertTrue(discovered ~= nil, "DiscoverSubAddons upserts a category")
assertEq(discovered.enabled, false, "discovered categories start disabled until enablement refresh")
assertEq(discovered.enablementResolved, false, "discovered categories start unresolved")
assertEq(discovered.group, "Optional", "discovered categories default to Optional")
assertEq(#UI:GetPagesForCategory("SpectrumFederation_CursedSurgeTracker"), 0, "discovered category has no synthetic pages")

local enableNotified = notified
UI:RefreshSubAddonEnablement({
    UnitGUID = function()
        return "Player-GUID"
    end,
    GetAddOnEnableState = function(name, character)
        assertEq(character, "Player-GUID", "refresh uses the player GUID")
        if name == "SpectrumFederation_CursedSurgeTracker" then
            return 2
        end
        return 0
    end,
    AddOnEnableState = { All = 2 },
})
assertEq(discovered.enabled, true, "enablement refresh sets enabled when state is All")
assertEq(discovered.enablementResolved, true, "enablement refresh marks the category resolved")
assertTrue(notified > enableNotified, "enablement refresh notifies when a value changes")

local unchangedNotified = notified
UI:RefreshSubAddonEnablement({
    UnitGUID = function()
        return "Player-GUID"
    end,
    GetAddOnEnableState = function()
        return 2
    end,
    AddOnEnableState = { All = 2 },
})
assertEq(notified, unchangedNotified, "identical enablement refresh does not notify")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
