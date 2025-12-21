# Copilot Instructions for SpectrumFederation

AI coding agent guidance for the **SpectrumFederation** World of Warcraft addon.

## Project Overview

**SpectrumFederation** is a WoW addon for the Spectrum Federation guild on Garona, written in **Lua 5.1** (WoW's embedded version). It tracks loot profiles and provides a loot helper system for guild management.

**Key Architecture:**
- `SpectrumFederation/` - All addon code (packaged for WowUp/CurseForge)
- `SpectrumFederation.toc` - Manifest with load order and version (MUST bump for PRs)
- `SF` (namespace) pattern - Shared state via `local addonName, SF = ...`
- SavedVariables - `SpectrumFederationDB` (profiles), `SpectrumFederationDebugDB` (logging)
- Module organization: `SF.Debug`, profile management functions

**Current File Structure:**
- `SpectrumFederation.lua` - Entry point, event registration, database init
- `modules/debug.lua` - Debug logging system with levels (VERBOSE/INFO/WARN/ERROR)
- `modules/LootProfiles.lua` - Profile CRUD operations (Create, Read, Update, Delete)
- `modules/settings_ui.lua` - Main settings panel with banner
- `modules/settings.lua` - Settings management
- `modules/core.lua` - Legacy core functionality (may be deprecated)
- `settings/loot_helper.lua` - Loot Helper UI section with profile management
- `settings/loot_profiles_ui.lua` - Legacy file (superseded by loot_helper.lua)
- `locale/enUS.lua` - Localization strings

## Critical Branch & Version Rules

**Branch Model (STRICTLY ENFORCED BY CI):**
- `main` - Stable releases (version: `X.Y.Z`)
- `beta` - Beta/PTR releases (version: `X.Y.Z-beta.N`)

**Version Bumping (CI FAILS WITHOUT):**
- Every behavioral change to `main` or `beta` MUST bump `## Version:` in `SpectrumFederation.toc`
- Beta versions can ONLY be released from `beta` branch
- Stable versions can ONLY be released from `main` branch
- CI validates branch/version alignment - do NOT edit workflows to bypass this

**Release Process:**
- Tags and GitHub releases auto-created by `release.yml` workflow
- Never manually create or move git tags
- Package layout validated for WowUp/CurseForge compatibility

## Lua Environment & WoW API

**Language:** Lua 5.1 ONLY (not 5.2+)
- No `goto`, bitwise operators, or extended standard library
- No `io` or `os` libraries (WoW sandbox)
- Use WoW API: `CreateFrame`, `UnitName`, `GetRealmName`, etc.
- Reference `BlizzardUI/live/` or `BlizzardUI/beta/` for API examples (git-ignored, dev container generates)

**TOC File Load Order (SpectrumFederation.toc):**
```
SpectrumFederation.lua         # Entry point, event registration, DB init
modules/debug.lua              # Debug logging system (load early)
modules/LootProfiles.lua       # Profile CRUD operations
settings/loot_helper.lua       # Loot Helper UI section
modules/settings_ui.lua        # Main settings panel frame
```

**Adding New Files:**
1. Create under appropriate directory:
   - `SpectrumFederation/modules/` for core functionality
   - `SpectrumFederation/settings/` for UI sections
2. Add to `.toc` after dependencies, before dependents
3. Use namespace pattern: `local addonName, SF = ...`
4. For settings sections: Create a function like `SF:CreateYourSection(panel, anchorFrame)`

## Namespace & SavedVariables Pattern

**Namespace Usage (`SF`):**
```lua
local addonName, SF = ...

-- Direct function definitions on SF namespace
function SF:CreateNewLootProfile(profileName)
    -- Profile creation logic
end

function SF:SetActiveLootProfile(profileName)
    -- Profile switching logic
end

-- Module organization for debug system
SF.Debug     -- Logging system (debug.lua)

-- SavedVariables references (set in SpectrumFederation.lua)
SF.db        -- Points to SpectrumFederationDB
SF.debugDB   -- Points to SpectrumFederationDebugDB
```

**SavedVariables Structure:**
```lua
-- SpectrumFederationDB (declared in .toc)
{
    lootProfiles = {
        ["ProfileName"] = {
            name = "ProfileName",
            owner = "PlayerName",
            server = "RealmName",
            admins = { "PlayerName-RealmName" },
            created = timestamp,
            modified = timestamp
        }
    },
    activeLootProfile = "ProfileName"  -- Current active profile
}

-- SpectrumFederationDebugDB (debug logging)
{
    enabled = false,
    logs = {},           -- Array of log entries
    maxEntries = 500
}
```

**Character Keys:** Always use `"Name-Realm"` format (e.g., `"Shadowbane-Garona"`)

## Code Patterns & Conventions

**Event Handling (SpectrumFederation.lua):**
```lua
local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("PLAYER_LOGIN")
EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- Initialize DebugDB
        if not SpectrumFederationDebugDB then
            SpectrumFederationDebugDB = { enabled = false, logs = {}, maxEntries = 500 }
        end
        SF.debugDB = SpectrumFederationDebugDB
        
        -- Initialize Debug System
        if SF.Debug then
            SF.Debug:Initialize()
            SF.Debug:Info("ADDON", "SpectrumFederation addon loaded")
        end
        
        -- Initialize Database
        SF:InitializeDatabase()
        
        -- Create Settings UI
        if SF.CreateSettingsUI then
            SF:CreateSettingsUI()
        end
    end
end)
```

**Module Pattern for Debug (debug.lua):**
```lua
local addonName, SF = ...

local Debug = SF.Debug or {}
SF.Debug = Debug

function Debug:Log(level, category, message, ...)
    if not self:IsEnabled() then return end
    -- Log to SF.debugDB.logs
end

function Debug:Initialize()
    if SF.debugDB then
        self.enabled = SF.debugDB.enabled or false
    end
end
```

**Profile Functions (LootProfiles.lua):**
```lua
local addonName, SF = ...

function SF:CreateNewLootProfile(profileName)
    -- Validation, creation logic
    if SF.Debug then SF.Debug:Info("PROFILES", "Created new profile '%s'", profileName) end
end

function SF:SetActiveLootProfile(profileName)
    SF.db.activeLootProfile = profileName
    if SF.Debug then SF.Debug:Info("PROFILES", "Set active profile to '%s'", profileName) end
end

function SF:DeleteProfile(profileName)
    SF.db.lootProfiles[profileName] = nil
    if SF.Debug then SF.Debug:Info("PROFILES", "Deleted profile '%s'", profileName) end
end
```

**Debug Logging (use everywhere):**
```lua
if SF.Debug then
    SF.Debug:Info("CATEGORY", "Message with %s", arg)
    SF.Debug:Error("CATEGORY", "Error occurred")
    SF.Debug:Verbose("CATEGORY", "Detailed info")
    SF.Debug:Warn("CATEGORY", "Warning message")
end
```

**Settings UI Structure (settings_ui.lua + settings/loot_helper.lua):**
```lua
-- Main settings panel (settings_ui.lua)
function SF:CreateSettingsUI()
    local panel = CreateFrame("Frame", nil, UIParent)
    
    -- Banner (90% width, auto-scales)
    local banner = panel:CreateTexture(nil, "ARTWORK")
    -- ... banner setup ...
    
    -- Create sections (add more as needed)
    SF:CreateLootHelperSection(panel, banner)
    
    -- Register with Settings API
    local category = Settings.RegisterCanvasLayoutCategory(panel, "Spectrum Federation")
    Settings.RegisterAddOnCategory(category)
end

-- Section file (settings/loot_helper.lua)
function SF:CreateLootHelperSection(panel, anchorFrame)
    -- Create subtitle with horizontal lines (90% width)
    -- Create profile dropdown
    -- Create profile management UI
end
```

## CI/CD Workflows (DO NOT MODIFY)

**Automated Checks:**
1. `linter.yml` - Runs `luacheck` (Lua 5.1 rules) and `yamllint`
2. `validate-packaging.yml` - Ensures WowUp/CurseForge zip structure
3. `check-version-bump.sh` - Fails PR if version unchanged
4. `release.yml` - Auto-tags and releases on version bump
5. `update-changelog.yml` - Auto-generates changelog using GitHub Copilot
6. `deploy-docs.yml` - MkDocs to GitHub Pages

**Changelog Workflow:**
- **Beta branch**: Changes go to `## [Unreleased - Beta]` section
- **Main branch**: Changes go to versioned releases (e.g., `## [0.0.15] - 2025-12-21`)
- **Auto-cleanup**: When beta merges to main, the Unreleased - Beta section is automatically removed
- Uses GitHub Copilot to analyze git diffs and generate changelog entries

**Luacheck (.luacheckrc):**
- Declares WoW API globals: `CreateFrame`, `C_Timer`, etc.
- Add new WoW APIs here instead of using `-- luacheck: ignore`
- Run locally: `luacheck SpectrumFederation --only 0`

**Packaging Requirements:**
- Zip must contain exactly one folder: `SpectrumFederation/`
- Must have `SpectrumFederation.toc` with valid `## Interface:` line
- WowUp/CurseForge compatibility validated before merge

## Development Workflow

**Dev Container (.devcontainer/):**
- Ubuntu with Lua 5.1, luacheck, luarocks pre-installed
- Auto-generates `BlizzardUI/` (live + beta sources) for API reference
- VS Code extensions: Lua Language Server, WoW API autocomplete, GitHub Copilot

**Local Testing:**
1. Symlink `SpectrumFederation/` to WoW's `Interface/AddOns/`
2. Launch WoW, enable addon in addon list
3. Use `/reload` after code changes
4. Enable Lua errors: `/console scriptErrors 1`
5. Test slash commands: `/sfdebug on`, `/sfdebug show`

**Before Submitting PR:**
```bash
# Lint code
luacheck SpectrumFederation --only 0

# Bump version in SpectrumFederation.toc
## Version: 0.0.15-beta.1  # (or next appropriate version)

# Test in-game with /reload
```

## Common Tasks

**Adding a Feature:**
1. Create feature branch from `beta` (experimental) or `main` (stable)
2. Add Lua file in `SpectrumFederation/modules/`
3. Update `.toc` file load order
4. Use namespace pattern and debug logging
5. Bump version in `.toc`
6. Test in-game, run `luacheck`
7. PR to appropriate branch

**Database Changes:**
- Always check/initialize in `SF:InitializeDatabase()`
- Log changes with `SF.Debug:Info()`
- Access via `SF.db` (never direct `SpectrumFederationDB`)
- Profile data: `SF.db.lootProfiles[profileName]`
- Active profile: `SF.db.activeLootProfile`

**UI Components:**
- Create main panel in `modules/settings_ui.lua`
- Create UI sections in `settings/` directory
- Store UI elements in SF namespace (e.g., `SF.LootProfileDropdown`)
- Use `UIParent` as parent for main frames
- Banner scales to 90% of panel width with aspect ratio preserved

## Documentation

**MkDocs (docs/):**
- Material theme, auto-deploys to GitHub Pages
- Run locally: `pip install -r requirements-docs.txt && mkdocs serve`
- Add feature docs in `docs/` when adding user-facing features

## Critical Rules - DO NOT VIOLATE

**Version Management:**
- ❌ Never skip version bump in `.toc` for behavioral changes
- ❌ Never release beta versions from `main` branch
- ❌ Never release stable versions from `beta` branch
- ❌ Never edit workflow files to bypass version checks
- ❌ Never manually create or move git tags

**Code Location:**
- ❌ Never place addon code outside `SpectrumFederation/`
- ❌ Never commit `BlizzardUI/` folder (it's git-ignored)
- ❌ Never create runtime dependencies on `BlizzardUI/`

**Lua Compatibility:**
- ❌ Never use Lua 5.2+ features (goto, bitwise ops, extended libs)
- ❌ Never use `io` or `os` libraries (WoW sandboxed)
- ❌ Never create globals without adding to `.luacheckrc`

**TOC File:**
- ❌ Never add Lua files without updating `.toc` load order
- ❌ Never load files before their dependencies

**SavedVariables:**
- ✅ Always access via `SF.db` and `SF.debugDB`
- ✅ Always initialize in `SF:InitializeDatabase()`
- ✅ Profile data stored in `SF.db.lootProfiles`

**Best Practices:**
- ✅ Use debug logging extensively: `SF.Debug:Info("CATEGORY", "message")`
- ✅ Follow module pattern: `local Module = SF.Module or {}; SF.Module = Module`
- ✅ Use character keys: `"Name-Realm"` format
- ✅ Test with `/reload` and `/console scriptErrors 1`
- ✅ Run `luacheck` before committing
- ✅ Add localization strings to `locale/enUS.lua`

## Quick Reference

**File Structure:**
```
SpectrumFederation/
├── SpectrumFederation.lua    # Entry point, events
├── SpectrumFederation.toc    # MUST bump version
├── modules/
│   ├── core.lua              # Legacy (may be deprecated)
│   ├── debug.lua             # Logging system
│   ├── LootProfiles.lua      # Profile CRUD
│   ├── settings_ui.lua       # Main settings panel
│   └── settings.lua          # Settings management
├── settings/
│   ├── loot_helper.lua       # Loot Helper section (active)
│   └── loot_profiles_ui.lua  # Legacy (superseded)
├── locale/
│   └── enUS.lua              # Localization
└── media/                    # Icons, textures
```

**Key Commands:**
- Lint: `luacheck SpectrumFederation --only 0`
- Test: Copy to WoW, use `/reload`
- Debug: `/sfdebug on|off|show`
- Docs: `mkdocs serve` (after `pip install -r requirements-docs.txt`)

**Version Format:**
- Main: `0.0.14` (stable)
- Beta: `0.0.14-beta.1` (experimental)

**Resources:**
- WoW API Docs: [https://wowpedia.fandom.com/wiki/World_of_Warcraft_API](https://wowpedia.fandom.com/wiki/World_of_Warcraft_API)
- BlizzardUI Reference: `BlizzardUI/live/` or `BlizzardUI/beta/` (local only)
- Extended guidance: `AGENTS.md`



