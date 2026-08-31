# Settings System

The settings implementation separates persistence, runtime effects, page registration, and rendering. User-facing option descriptions belong on [Settings](../../settings-ui.md); this page describes how to extend the system.

## Components

| File | Role |
| --- | --- |
| `modules/Settings/Schema.lua` | Account-wide and character defaults, enums, and migrations. |
| `modules/Settings/Store.lua` | Dot-path reads/writes, callbacks, resets, profile adapters, and per-character storage. |
| `modules/Settings/Apply.lua` | Debouncing, combat deferral, and feature reactions. |
| `modules/UI/Settings/Registry.lua` | Canonical page and category inventory, `RegisterCategory` for empty parent-owned categories, `categoryId` normalization, sub-addon discovery, and enablement refresh. Blizzard Settings registration is currently disabled. |
| `modules/UI/Settings/NavigationModel.lua` | Pure navigation helpers (content pages, `ShowPage`, search ranking, sort, window minima). No frames and no C_AddOns. |
| `modules/UI/Settings/SubAddons.lua` | C_AddOns adapter used only by Registry. |
| `modules/UI/Settings/StandaloneWindow.lua` | The `/sf` window: category sidebar, tabs, session last-tab, search, resize. |
| `modules/UI/Settings/Widgets/TabBar.lua` | Content tab strip for categories with two or more pages. |
| `modules/UI/Settings/Widgets/EmptyState.lua` | Generic empty category presentation. |
| `modules/UI/Settings/PageBuilder.lua` | Scroll hosts, sections, sizing, refresh, and reflow. |
| `modules/UI/Settings/DefinitionRenderer.lua` | Declarative section/control definitions and refresh bindings. |
| `modules/UI/Settings/Control/Controls.lua` | Concrete control builders. |
| `modules/UI/Settings/Dialogs.lua` | Confirmation, prompt, and Main Swap dialogs. |
| `modules/UI/Settings/Pages/` | Registered user-facing pages. |

Registry is the only inventory. NavigationModel receives Registry data as arguments and does not keep a second copy of categories or pages. The window owns frames and session state (`currentCategoryId`, `currentPageId`, `lastPageByCategory`). Last-tab is in-memory only; it is not persisted.

## Categories and pages

The sidebar shows **top-level categories only**. Nested sidebar children are not used.

- New pages set `categoryId` to the category they belong to.
- Legacy `parentId` is still accepted and becomes `categoryId`. If both are set and differ, registration errors.
- A page whose `id` equals its `categoryId` is the category root. If other pages share that category, the root is metadata only (`name`, `navLabel`, `group`, `description`, `defaultChildId`, `order`) and is **not** a tab. Loot Helper is the current example: five content pages, not six.
- A root with no children is itself the one content page (General, Loot Logs, Debugging).
- Zero content pages: show the empty-state widget. Do not register a synthetic page. Gameplay is the parent-owned example; discovered child addons can also be empty.
- One content page: hide the tab bar.
- Two or more: show tabs.

Discovered child addons default to group **Optional**. Parent-owned categories keep Core / Loot Tools / Advanced.

`ShowPage(id)` is deterministic and ignores last-tab. `ShowPage("lootHelper")` opens `lootHelperGeneral`. Sidebar clicks restore last-tab for that category when it is still valid. `/sf` may restore this session; `/reload` does not.

Quick Find matches `name`, `navLabel`, `description`, and `group` on categories and content pages. Ranking is exact → prefix → substring on name/navLabel, then description, then group, then `order`, then `id`. Pages beat category-only hits at the same rank. With a query, clicking a category opens the best matching page in that category.

## Sub-addon discovery

Child addons declare:

```toc
## Group: SpectrumFederation
## Dependencies: SpectrumFederation
## X-SpectrumFederation-Parent: SpectrumFederation
```

Discovery reads `X-SpectrumFederation-Parent` (not `## Group`) and matches the parent addon name case-insensitively. The parent TOC must not load child Lua.

Installed children are discovered at Settings Init (`ADDON_LOADED`). Character enablement uses `C_AddOns.GetAddOnEnableState(name, UnitGUID("player")) == Enum.AddOnEnableState.All` and is refreshed on `PLAYER_LOGIN` and at the start of `Show()` if still unresolved. Do not treat `lootHelper.enabled` as category enablement.

Disabled categories stay visible and grey. Mouse stays enabled so the tooltip can explain that the add-on must be enabled in WoW's AddOns list. `/sf` cannot enable or disable child addons.

## Window size

`layout.windowWidth` and `layout.windowHeight` are preferred minima of the whole Settings window, clamped to `UIParent` minus margins. The window grows if it is smaller than the effective minimum and does not auto-shrink when leaving a wide page except to stay on screen. `OnSizeChanged` is layout-only and must not call `page:Refresh()`, Store, sync, or inspect.

## Add a persisted setting

1. Add an account-wide default to `SettingsSchema.DEFAULTS`, or a per-character default to `CHARACTER_DEFAULTS`.
2. Read and write it through `SF.SettingsStore`.
3. Add the control to the appropriate page.
4. Register any runtime reaction in the owning feature or `SettingsApply`.
5. Add a migration only when existing saved data must change shape.
6. Document the visible behavior on the user settings page.

```lua
-- Schema.lua
global = {
    exampleEnabled = false,
}

-- Feature code
local enabled = SF.SettingsStore:Get("global.exampleEnabled")
SF.SettingsStore:Set("global.exampleEnabled", true)
```

`Store:Set(path, value)` writes immediately and fires callbacks registered for that exact path:

```lua
SF.SettingsStore:RegisterCallback("global.exampleEnabled", function(newValue, oldValue, path)
    -- Keep this callback small; defer protected or repeated work as needed.
end)
```

The callback API is path-first. Older documentation that shows an arbitrary callback ID or the legacy namespaced Store form does not match the current implementation.

## Add a page

A page is an object with metadata plus `Build` and optional `Refresh` methods:

```lua
local Page = {
    id = "example",
    name = "Example",
    navLabel = "Example",
    group = "Core",
    description = "Configure the example feature.",
    order = 25,
}

function Page:Build(panel)
    SF.SettingsUI.DefinitionRenderer:Build(panel, {
        sections = {
            {
                id = "general",
                title = "General",
                items = {
                    {
                        type = "checkbox",
                        label = "Enable Example",
                        tooltip = "Turn the example feature on or off.",
                        path = "global.exampleEnabled",
                    },
                },
            },
        },
    })
end

function Page:Refresh(panel)
    SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

SF.SettingsUI:RegisterPage(Page)
```

Add the page file to `SpectrumFederation.toc` after the registry, renderer, and controls and before initialization.

Use `categoryId` (canonical) or legacy `parentId` so the page becomes a tab of that category. If the category root's `id` matches `categoryId` and other pages share the category, the root is metadata only and must not be a sixth tab. Keep `id` stable because other modules can open pages with `SF.SettingsWindow:ShowPage(id)`.

To reserve a sidebar category before it has pages, register the category only:

```lua
SF.SettingsUI:RegisterCategory({
    id = "example",
    name = "Example",
    navLabel = "Example",
    group = "Core",
    description = "Configure the example feature.",
    order = 25,
})
```

Do not register a synthetic page for an empty category. The empty-state widget is shown until a content page is registered with that `categoryId`.

Navigation tests load production `NavigationModel.lua`:

```bash
python -m pytest tests/test_settings_navigation.py
```

## Declarative controls

`DefinitionRenderer` currently supports:

- text, heading, title divider, spacer, help, and key/value box;
- checkbox, checkbox row/grid, slider, dropdown, display, and edit box;
- buttons, button rows, inline controls, edit-box/button, and dropdown/icon-button composites;
- scroll list, scrollable text, log table, and template editor.

Prefer a `path` for ordinary persisted values. Use custom `get`/`set` functions for profile methods, validation, computed state, or temporary panel state.

Common dynamic fields include `visible`, `enabled`, and `adminOnly`. `adminOnly` disables presentation for non-admins, but domain methods must still enforce permission checks.

Callbacks receive a context containing `panel`, `section`, `store`, `schema`, `ui`, and `pageBuilder`. Use it to show section messages and refresh/reflow after structural changes.

## Profile settings

Loot profiles are domain objects, not ordinary schema subtrees. The Store methods under `GetActiveLootHelperProfileObject`, `CreateLootHelperProfile`, admin management, rename, reset, and Main Swap adapt settings pages to `LootProfile` methods.

Do not add profile-authoritative data only to `SettingsSchema.PROFILE_SETTINGS_DEFAULTS`; define it on `LootProfile`, include it in snapshots when synchronization requires it, and expose validated getters/setters.

## Combat and deferred apply

Use `SettingsApply:Debounce(token, delay, fn)` for rapid repeated changes and `RunOrDefer(fn)` for work that must wait until combat ends.

Character-specific settings belong in `CHARACTER_DEFAULTS` and are read or written through `Store:GetCharacter` / `Store:SetCharacter`. Register any runtime reaction in the owning feature or `SettingsApply`.

## Review checklist

- Defaults and migrations preserve existing SavedVariables.
- Page and setting IDs remain stable.
- Runtime behavior changes when the setting changes.
- The selected write path enforces permissions independently of UI state; add an explicit check when a low-level mutator does not.
- Tooltips explain user behavior, not implementation.
- `/reload` and combat deferral are tested where relevant.
- New Lua files appear in TOC load order and the addon version is bumped.
- New pages use `categoryId` (or legacy `parentId`) and do not add nested sidebar children.
- A category root with child pages is metadata only and is not a tab.
- Settings navigation changes run `python -m pytest tests/test_settings_navigation.py`.
