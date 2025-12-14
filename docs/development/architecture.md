# Architecture

This document describes the technical architecture of the Spectrum Federation addon.

## Directory Structure

```
SpectrumFederation/
├── SpectrumFederation.lua    # Main entry point, event handling
├── SpectrumFederation.toc    # Addon manifest (CRITICAL)
├── locale/
│   └── enUS.lua             # English localization
├── media/
│   ├── Fonts/               # Custom fonts
│   ├── Icons/               # Icons and small graphics
│   └── Textures/            # Larger textures
└── modules/
    ├── core.lua             # Core logic and utilities
    └── ui.lua               # UI elements and frames
```

## TOC File

The `.toc` file is the addon manifest and controls:

- **Loading order** - Files load in the order listed
- **Metadata** - Title, version, author, etc.
- **Interface version** - Game version compatibility

Key fields:
```
## Interface: 120000          # WoW API version (12.0.0)
## Version: 0.0.5-beta        # Addon version (MUST bump in PRs)
## Title: Spectrum Federation # Display name
```

## Namespace Pattern

All modules use the standard WoW addon namespace:

```lua
local addonName, ns = ...
```

The `ns` table is shared across all files and stores:
- `ns.L` - Localization strings
- `ns.core` - Core functions
- `ns.ui` - UI functions
- Custom data and utilities

## Module Responsibilities

### SpectrumFederation.lua (Main)

- Creates the main addon frame
- Registers events (`PLAYER_LOGIN`, etc.)
- Dispatches to module functions
- Minimal logic, mostly delegation

Example:
```lua
local addonName, ns = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" and ns.core.OnPlayerLogin then
        ns.core.OnPlayerLogin(...)
    end
end)
```

### modules/core.lua

- Business logic
- Data processing
- Utility functions
- Non-UI functionality

Store functions in `ns.core`:
```lua
local addonName, ns = ...
ns.core = ns.core or {}

function ns.core.OnPlayerLogin()
    print("Core: Player logged in")
end
```

### modules/ui.lua

- Frame creation
- UI event handlers
- Visual elements
- User interaction

Store functions in `ns.ui`:
```lua
local addonName, ns = ...
ns.ui = ns.ui or {}

function ns.ui.CreateMainFrame()
    local frame = CreateFrame("Frame", "SFMainFrame", UIParent)
    -- UI setup...
    return frame
end
```

### locale/enUS.lua

- All user-facing text
- Localization keys
- Stored in `ns.L`

```lua
local addonName, ns = ...
local L = ns.L or {}
ns.L = L

L["ADDON_LOADED"] = "Spectrum Federation loaded!"
L["WELCOME_MSG"] = "Welcome, %s!"
```

## Event Handling

Events are registered in the main file and delegated to modules:

```lua
-- Register
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ADDON_LOADED")

-- Handle
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        ns.core.OnPlayerLogin(...)
    elseif event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            ns.core.OnAddonLoaded()
        end
    end
end)
```

## WoW API Usage

### Common APIs

- `CreateFrame(type, name, parent)` - Create UI frames
- `print(...)` - Print to chat
- `UnitName("player")` - Get player name
- `GetRealmName()` - Get realm name
- `C_Timer.After(delay, callback)` - Delayed execution

### Colored Output

Use color codes in strings:
```lua
print("|cff00ff00Green text|r normal text")
-- |cffRRGGBB starts color
-- |r resets color
```

### Frame Hierarchy

```
UIParent (root)
  └── Your custom frame
        └── Child frames (buttons, text, etc.)
```

## Development Workflow

1. **Feature branch** from `beta`
2. **Edit** files in `SpectrumFederation/`
3. **Add** new files to `.toc` if needed
4. **Test** in-game (copy to WoW `AddOns` folder)
5. **Lint** with `luacheck`
6. **Bump** version in `.toc`
7. **Commit** and create PR to `beta`

## CI/CD Pipeline

### On Pull Request

1. **Luacheck** - Validates Lua syntax
2. **Version bump check** - Ensures version incremented
3. **Packaging validation** - Verifies addon structure

### On Merge to main/beta

1. **Auto-tag** - Creates git tag from version
2. **Build zip** - Packages `SpectrumFederation/` folder
3. **GitHub Release** - Uploads artifact
   - `beta` branch → pre-release
   - `main` branch → full release

## Lua 5.1 Constraints

WoW uses **Lua 5.1**, which means:

- ❌ No `goto` statements
- ❌ No bitwise operators (`&`, `|`, `<<`, etc.)
- ❌ No `\z` escape sequence
- ✅ Use `bit` library for bitwise ops (provided by WoW)
- ✅ Use `string.format` for string building

## Best Practices

### Avoid Globals

❌ Bad:
```lua
myGlobalVar = 123
```

✅ Good:
```lua
ns.myVar = 123
```

### Use Locals

❌ Bad:
```lua
function processData(data)
    result = {}  -- implicit global!
end
```

✅ Good:
```lua
local function processData(data)
    local result = {}
    return result
end
```

### Namespace Functions

❌ Bad:
```lua
function DoSomething()  -- global function
end
```

✅ Good:
```lua
function ns.core.DoSomething()
end
```

## BlizzardUI Reference

The dev container includes Blizzard's UI source code for reference:

- `BlizzardUI/live/` - Retail UI
- `BlizzardUI/beta/` - Beta/PTR UI

**Use for reference only** - don't create runtime dependencies on these paths.

## Further Reading

- [WoW API Documentation](https://wowpedia.fandom.com/wiki/World_of_Warcraft_API)
- [Lua 5.1 Reference](https://www.lua.org/manual/5.1/)
- [Copilot Instructions](../../.github/copilot-instructions.md) - Detailed development guidelines
