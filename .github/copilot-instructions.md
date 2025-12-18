# Copilot Instructions for SpectrumFederation

AI coding agent guidance for the **SpectrumFederation** World of Warcraft addon.

## Project Overview

**SpectrumFederation** is a WoW addon for the Spectrum Federation guild on Garona, written in **Lua 5.1** (WoW's embedded version). It tracks DKP-style points, raid participation, and loot distribution across WoW tiers.

**Key Architecture:**
- `SpectrumFederation/` - All addon code (packaged for WowUp/CurseForge)
- `SpectrumFederation.toc` - Manifest with load order and version (MUST bump for PRs)
- `ns` (namespace) pattern - Shared state via `local addonName, ns = ...`
- SavedVariables - `SpectrumFederationDB` (tier data), `SpectrumFederationDebugDB` (logging)
- Module organization: `ns.Core`, `ns.UI`, `ns.Debug`, `ns.LootLog`

**Current Modules:**
- `core.lua` - Database initialization, roster tracking, tier management
- `ui.lua` - Frame creation, UI components
- `debug.lua` - Debug logging system with levels (VERBOSE/INFO/WARN/ERROR)
- `lootLog.lua` - Audit trail for point changes

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
SpectrumFederation.lua      # Entry point, event registration
modules/core.lua            # Database, roster, tier management
modules/debug.lua           # Debug logging system
modules/lootLog.lua         # Point change audit log
modules/ui.lua              # UI frames and components
locale/enUS.lua             # Localization strings
```

**Adding New Files:**
1. Create under `SpectrumFederation/modules/`
2. Add to `.toc` after dependencies, before dependents
3. Use namespace pattern: `local addonName, ns = ...`
4. Create module table: `local MyModule = ns.MyModule or {}; ns.MyModule = MyModule`

## Namespace & SavedVariables Pattern

**Namespace Usage (`ns`):**
```lua
local addonName, ns = ...

-- Module organization (follow this pattern)
ns.Core     -- Database, tier data, roster (core.lua)
ns.UI       -- Frame creation, UI elements (ui.lua)
ns.Debug    -- Logging system (debug.lua)
ns.LootLog  -- Audit trail (lootLog.lua)
ns.L        -- Localization strings (locale/enUS.lua)

-- SavedVariables references (set in SpectrumFederation.lua)
ns.db       -- Points to SpectrumFederationDB
ns.debugDB  -- Points to SpectrumFederationDebugDB
```

**SavedVariables Structure:**
```lua
-- SpectrumFederationDB (declared in .toc)
{
    schemaVersion = 1,
    currentTier = "0.0.14",  -- Active tier version
    tiers = {
        ["0.0.14"] = {
            points = {},      -- charKey -> point total
            logs = {},        -- id -> log entry
            nextLogId = 1
        }
    },
    ui = {
        lootFrame = { position = nil, isShown = false }
    }
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
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        InitializeNamespace()  -- Set ns.db, ns.debugDB
        ns.Debug:Initialize()
        ns.Core:OnPlayerLogin()
    end
end)
```

**Module Methods (use colon syntax):**
```lua
function Core:InitDatabase()
    if not ns.db then ns.db = SpectrumFederationDB or {} end
    -- Initialize with default structure
end

function Debug:Log(level, category, message, ...)
    if not self:IsEnabled() then return end
    -- Log to ns.debugDB.logs
end
```

**Debug Logging (use everywhere):**
```lua
if ns.Debug then
    ns.Debug:Info("CATEGORY", "Message with %s", arg)
    ns.Debug:Error("CATEGORY", "Error occurred")
    ns.Debug:Verbose("CATEGORY", "Detailed info")
end
```

**Localization:**
```lua
-- In locale/enUS.lua
local L = ns.L
L["ADDON_LOADED"] = "Spectrum Federation loaded!"

-- Usage
print(ns.L["ADDON_LOADED"])
```

**Slash Commands (SpectrumFederation.lua):**
```lua
SLASH_SFDEBUG1 = "/sfdebug"
SlashCmdList["SFDEBUG"] = function(msg)
    -- Parse msg and call ns.Debug methods
end
```

## CI/CD Workflows (DO NOT MODIFY)

**Automated Checks:**
1. `linter.yml` - Runs `luacheck` (Lua 5.1 rules) and `yamllint`
2. `validate-packaging.yml` - Ensures WowUp/CurseForge zip structure
3. `check-version-bump.sh` - Fails PR if version unchanged
4. `release.yml` - Auto-tags and releases on version bump
5. `deploy-docs.yml` - MkDocs to GitHub Pages

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
- Always check/initialize in `Core:InitDatabase()`
- Use `ns.Core:GetCurrentTierData()` for tier-specific data
- Log changes with `ns.Debug:Info()`
- Access via `ns.db` (never direct `SpectrumFederationDB`)

**UI Components:**
- Create frames in `modules/ui.lua`
- Store position in `ns.db.ui` for persistence
- Use `UIParent` as parent for main frames
- Register for events with `frame:RegisterEvent()`

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
- ✅ Always access via `ns.db` and `ns.debugDB`
- ✅ Always initialize in `Core:InitDatabase()`
- ✅ Always use `ns.Core:GetCurrentTierData()` for tier data

**Best Practices:**
- ✅ Use debug logging extensively: `ns.Debug:Info("CATEGORY", "message")`
- ✅ Follow module pattern: `local Module = ns.Module or {}; ns.Module = Module`
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
│   ├── core.lua              # Database, tier data
│   ├── debug.lua             # Logging system
│   ├── lootLog.lua           # Audit trail
│   └── ui.lua                # UI components
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



