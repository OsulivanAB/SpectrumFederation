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
- `modules/core.lua` - **REMOVED** (empty file, not loaded in TOC)
- `settings/loot_helper.lua` - Loot Helper UI section with profile management
- `locale/enUS.lua` - Localization strings (not yet loaded in TOC or used)

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
- Beta releases: Auto-created by `post-merge-beta.yml` after PR merge to beta
- Stable releases: Manual promotion via `promote-beta-to-main.yml` workflow (admin only)
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

**Localization:** The `locale/enUS.lua` file exists but is not yet loaded in the TOC or used in the codebase. It uses `ns.L` namespace pattern. When implementing localization, add the file to the TOC after modules and update code to use localization strings.

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

## CI/CD Workflows

**Active Workflows:**
1. **`linter.yml`** - Continuous linting (Lua, YAML, Python) using `.github/scripts/lint_all.py`
2. **`pr-beta-validation.yml`** - PR validation for beta branch:
   - Lint checks
   - Package validation (`.github/scripts/validate_packaging.py`)
   - Version bump check (`.github/scripts/check_version_bump.py`)
   - Duplicate release check (`.github/scripts/check_duplicate_release.py`)
3. **`post-merge-beta.yml`** - Automated beta releases after merge:
   - Sanity checks
   - Blizzard API query for beta Interface version
   - Changelog update (`.github/scripts/update_changelog.py`)
   - README badge update
   - Beta release creation (`.github/scripts/publish_release.py`)
4. **`promote-beta-to-main.yml`** - Manual promotion workflow (admin only):
   - Merges beta → main with special CHANGELOG/README handling
   - Removes `-beta` suffix from version
   - Updates Interface version using Blizzard live API
   - Updates changelog and README
   - Deploys MkDocs documentation
   - Creates stable release
   - Fast-forwards beta to main
   - Supports dry-run mode
5. **`rollback-release.yml`** - Emergency rollback for failed promotions (admin only)

**Python Helper Scripts (`.github/scripts/`):**
- All CI automation uses Python 3.11 scripts instead of bash
- Scripts are self-contained and can be run locally for testing
- See `.github/scripts/` directory for implementation details

**Changelog Management:**
- **Beta branch**: Changes go to `## [Unreleased - Beta]` section
- **Main branch**: Changes go to versioned releases (e.g., `## [0.0.17] - 2025-12-22`)
- Uses GitHub Copilot API to analyze git diffs and generate entries
- Automatic cleanup when beta promotes to main

**Local Testing:**
- Luacheck: `luacheck SpectrumFederation --only 0`
- Unified linter: `python3 .github/scripts/lint_all.py`
- Package validation: `python3 .github/scripts/validate_packaging.py`
- Declares WoW API globals in `.luacheckrc` - add new APIs there instead of using `-- luacheck: ignore`

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
│   ├── debug.lua             # Logging system
│   ├── LootProfiles.lua      # Profile CRUD
│   └── settings_ui.lua       # Main settings panel
├── settings/
│   └── loot_helper.lua       # Loot Helper section
├── locale/
│   └── enUS.lua              # Localization (not yet loaded)
└── media/                    # Icons, textures
```

**Key Commands:**
- Lint: `luacheck SpectrumFederation --only 0`
- Test: Copy to WoW, use `/reload`
- Slash command: `/sf` (opens settings panel)
- Docs: `mkdocs serve` (after `pip install -r requirements-docs.txt`)

**Version Format:**
- Main: `0.0.14` (stable)
- Beta: `0.0.14-beta.1` (experimental)

**Resources:**
- WoW API Docs: [https://wowpedia.fandom.com/wiki/World_of_Warcraft_API](https://wowpedia.fandom.com/wiki/World_of_Warcraft_API)
- BlizzardUI Reference: `BlizzardUI/live/` or `BlizzardUI/beta/` (local only)
- Extended guidance: `AGENTS.md`



