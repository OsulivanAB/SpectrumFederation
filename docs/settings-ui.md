# Settings UI

The Settings UI provides a modern, declarative framework for managing addon configuration. It features a data-driven architecture with automatic state management, validation, and reactive updates.

## Features

**Declarative Page Definitions**

- Define settings pages as data structures, not imperative code
- Automatic control creation from specifications
- Conditional visibility and section management

**13+ Control Types**

- Checkboxes, sliders, dropdowns, editboxes, buttons
- Read-only displays, help text, spacers
- Composite controls (dropdown + icon button, editbox + button)
- Scrollable lists with custom item templates

**Smart State Management**

- Path-based storage with dot notation (e.g., `"global.fontSize"`)
- Automatic binding between controls and settings
- Callback system for reactive updates
- Profile-specific settings isolation

**Combat-aware Operations**

- Queues UI operations during combat
- Automatic execution when safe
- Prevents frame errors during encounters

**Flexible Schema**

- Version migrations for data structure changes
- Validation system for user input
- Deep merge of defaults with user data

## Quick Example

```lua
-- Define a settings page
{
    {
        type = "section",
        title = "General Settings",
        controls = {
            {
                type = "checkbox",
                label = "Enable Feature",
                path = "myFeature.enabled",
                tooltip = "Enable or disable this feature"
            },
            {
                type = "slider",
                label = "Intensity",
                path = "myFeature.intensity",
                min = 0,
                max = 100,
                step = 5,
                format = "%d%%"
            }
        }
    }
}
```

That's it! The system automatically:

- Creates the UI controls
- Binds them to settings storage
- Saves changes immediately
- Triggers reactive updates
- Handles combat lockdown

## Architecture

The Settings UI system is organized into two main layers:

### Data Layer

**Schema** - Defines default values, enums, and version migrations

**Store** - Path-based storage with callbacks and profile management

**Apply** - Reactive effects that respond to setting changes (debounced and combat-aware)

### UI Layer

**Registry** - Page registration and lifecycle management

**PageBuilder** - Layout engine for scrollable pages with sections

**DefinitionRenderer** - Converts declarative page definitions into UI controls

**Controls** - 13+ control types with automatic state binding

**Dialogs** - Modal confirmation and prompt dialogs

**Pages** - Declarative page definitions (Main, LootHelper)

## Documentation

For detailed information, see the developer documentation:

- **[Architecture Overview](development/settings-ui/index.md)** - System architecture and key concepts
- **[Data Layer](development/settings-ui/data-layer.md)** - Schema, Store, and Apply modules
- **[UI Layer](development/settings-ui/ui-layer.md)** - Registry, PageBuilder, and DefinitionRenderer
- **[Controls Reference](development/settings-ui/controls.md)** - Available control types and usage
- **[Creating Pages](development/settings-ui/creating-pages.md)** - Guide to adding new settings pages
- **[Best Practices](development/settings-ui/best-practices.md)** - Design patterns and conventions

## Getting Started

### Accessing Settings

In-game, you can access settings via:

- **Slash Command**: `/sf`
- **Escape Menu**: ESC → Interface → AddOns → Spectrum Federation

### Adding a New Setting

1. **Define the default in Schema**:

```lua
-- modules/Settings/Schema.lua
DEFAULTS = {
    myFeature = {
        enabled = false
    }
}
```

2. **Add to a page**:

```lua
-- modules/UI/Settings/Pages/MyFeature.lua
{
    type = "checkbox",
    label = "Enable My Feature",
    path = "myFeature.enabled"
}
```

3. **Access the setting**:

```lua
local enabled = SF.Settings.Store:Get("myFeature.enabled")
```

That's all you need! The setting will automatically save to SavedVariables and persist across sessions.

## Current Pages

### Main Settings

Global addon configuration:

- Window style (Blizzard vs. Custom)
- Font family and size
- General addon preferences

### LootHelper Settings

LootHelper system configuration:

- Enable/disable LootHelper
- Profile management (create, rename, delete, import/export)
- Active profile selection
- Admin management (view admins, add/remove)
- Member management (view members)
- Raid-wide safe mode toggle

/// note | Work in Progress
The Settings UI is functional but some features are still under development:

- Import/Export functionality (UI present, backend pending)
- Admin management (add/remove admins)
- Full member management interface

Check the [GitHub project](https://github.com/users/OsulivanAB/projects/1) for current status.

///

## Integration

The Settings UI integrates with:

- **LootHelper** - Profile management and safe mode settings
- **Debug System** - All operations logged with appropriate levels
- **WoW API** - Blizzard Settings API for native integration
- **SavedVariables** - Persistent storage across sessions

## Performance

The Settings UI is designed for performance:

- **Lazy building** - Pages built only when first opened
- **Debounced updates** - Rapid changes coalesced into single operations
- **Combat queueing** - UI operations deferred during combat
- **Efficient rendering** - Conditional visibility skips hidden controls
- **Cached computations** - Expensive operations cached and reused

## Developer Resources

For contributors working on the Settings UI:

- Read the [Architecture Overview](development/settings-ui/index.md) to understand the system design
- Review [Best Practices](development/settings-ui/best-practices.md) for coding standards
- Follow the [Creating Pages](development/settings-ui/creating-pages.md) guide when adding features
- Use the [Controls Reference](development/settings-ui/controls.md) to choose appropriate control types
- Check the [Data Layer](development/settings-ui/data-layer.md) docs for state management patterns

## Feedback

Encounter issues or have suggestions? Please report them on our [GitHub Issues](https://github.com/OsulivanAB/SpectrumFederation/issues) page.
