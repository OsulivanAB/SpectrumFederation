# Settings System

The settings implementation separates persistence, runtime effects, page registration, and rendering. User-facing option descriptions belong on [Settings and Gameplay](../../settings-ui.md); this page describes how to extend the system.

## Components

| File | Role |
| --- | --- |
| `modules/Settings/Schema.lua` | Account-wide and character defaults, enums, and migrations. |
| `modules/Settings/Store.lua` | Dot-path reads/writes, callbacks, resets, profile adapters, and per-character storage. |
| `modules/Settings/Apply.lua` | Debouncing, combat deferral, CVar automation, and feature reactions. |
| `modules/UI/Settings/Registry.lua` | Page metadata and registration. Blizzard Settings registration is currently disabled. |
| `modules/UI/Settings/StandaloneWindow.lua` | The `/sf` window, grouped navigation, page lifecycle, and selected page. |
| `modules/UI/Settings/PageBuilder.lua` | Scroll hosts, sections, sizing, refresh, and reflow. |
| `modules/UI/Settings/DefinitionRenderer.lua` | Declarative section/control definitions and refresh bindings. |
| `modules/UI/Settings/Control/Controls.lua` | Concrete control builders. |
| `modules/UI/Settings/Dialogs.lua` | Confirmation, prompt, and Main Swap dialogs. |
| `modules/UI/Settings/Pages/` | Registered user-facing pages. |

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

The callback API is path-first. Older documentation that shows an arbitrary callback ID or `SF.Settings.Store` does not match the current implementation.

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

Use `parentId` and `defaultChildId` for nested navigation. Loot Helper is the current example. Keep `id` stable because other modules can open pages with `SF.SettingsWindow:ShowPage(id)`.

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

## Combat and CVar work

Use `SettingsApply:Debounce(token, delay, fn)` for rapid repeated changes and `RunOrDefer(fn)` for work that must wait until combat ends.

Press and Hold Casting is the complete character-setting example: Store maintains a specialization-keyed table, Apply listens for login/world/spec events, and the Gameplay page renders one checkbox per specialization.

## Review checklist

- Defaults and migrations preserve existing SavedVariables.
- Page and setting IDs remain stable.
- Runtime behavior changes when the setting changes.
- Domain methods enforce permissions independently of UI state.
- Tooltips explain user behavior, not implementation.
- `/reload`, specialization changes, and combat deferral are tested where relevant.
- New Lua files appear in TOC load order and the addon version is bumped.
