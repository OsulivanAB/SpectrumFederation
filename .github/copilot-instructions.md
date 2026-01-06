# Copilot Instructions for SpectrumFederation

AI coding agent guidance for the **SpectrumFederation** World of Warcraft addon.

## Project Overview

**SpectrumFederation** is a WoW addon for the Spectrum Federation guild on Garona, written in **Lua 5.1** (WoW's embedded version). It tracks loot profiles and provides a loot helper system for guild management.

## Key Architecture

**SpectrumFederation** is a WoW addon for the Spectrum Federation guild on Garona, written in **Lua 5.1** (WoW's embedded version). It tracks loot profiles and provides a loot helper system for guild management.

**Key Architecture:**
- `SpectrumFederation/` - All addon code (packaged for WowUp/CurseForge)
- `SpectrumFederation.toc` - Manifest with load order and version (MUST bump for PRs)
- `SF` (namespace) pattern - Shared state via `local addonName, SF = ...`
- SavedVariables - `SpectrumFederationDB` (profiles), `SpectrumFederationDebugDB` (logging)
- Module organization: `SF.Debug`, `SF.NameUtil`, `SF.Member`, `SF.LootLog`, `SF.LootProfile`, `SF.LootHelperSync`, `SF.LootHelperComm`, `SF.SyncProtocol`
- Third-party libraries: LibStub, AceComm-3.0, CallbackHandler, ChatThrottleLib (for addon communication)

**Profile Synchronization System:**
- **Log-replication model**: LootLogs are append-only, members derived by replay
- **Stable profile IDs**: Format `p_<time><random1><random2>` (24 hex chars)
- **Per-author counters**: Prevent log collisions in multi-writer scenarios
- **Session-based sync**: Coordinator (raid leader) manages helpers, broadcasts to raid
- **Admin convergence**: Pre-sync phase where admins exchange missing logs
- **Live updates**: Real-time NEW_LOG broadcasts with gap detection/repair
- **Safe mode**: Pause sync during combat or on-demand (session-wide or local)
- **Communication layers**: Control (SF_LH) for small messages, Bulk (SF_LHB) for large payloads
- **Protocol versioning**: Graceful fallback for version mismatches (PROTO_NACK)

**Current File Structure:**
- `SpectrumFederation.lua` - Entry point, event registration, database init
- `modules/debug.lua` - Debug logging system with levels (VERBOSE/INFO/WARN/ERROR)
- `modules/core.lua` - Core addon functionality (Now(), GetAddonVersion())
- `modules/NameUtil.lua` - Canonical name-realm normalization utilities
- `modules/MessageHelpers.lua` - Color-coded user messaging (PrintSuccess/Error/Warning/Info)
- `modules/SlashCommands.lua` - Slash command registration and profile management commands
- `modules/Settings.lua` - Main settings panel with banner
- `Libs/` - Third-party libraries (LibStub, AceComm, CallbackHandler, ChatThrottleLib)
- `modules/LootHelper/SyncProtocol.lua` - Protocol versioning and payload encoding/decoding
- `modules/LootHelper/Comm.lua` - Communication layer with AceComm integration
- `modules/LootHelper/Members.lua` - Member class (OOP pattern for loot profile members)
- `modules/LootHelper/LootLogValidators.lua` - Validation functions for loot logs
- `modules/LootHelper/LootLogs.lua` - LootLog class (immutable event logging with counters)
- `modules/LootHelper/Profiles.lua` - Profile CRUD with stable IDs and export/import
- `modules/LootHelper/LootHelper.lua` - Core loot helper functionality with schema migration
- `modules/LootHelperSync/` - 18 numbered modules for profile synchronization system
  - 00_Namespace.lua through 18_PublicAPI.lua (sequentially loaded)
  - Handles session management, peer discovery, request queueing, safe mode
  - Admin convergence, handshake, heartbeat, live updates, bulk transfers
- `modules/Settings.lua` - Main settings panel with banner

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
# --- Libs (load first) ---
Libs/LibStub/LibStub.lua
Libs/CallbackHandler/CallbackHandler-1.0.lua
Libs/AceComm/ChatThrottleLib.lua
Libs/AceComm/AceComm-3.0.lua

# --- Core modules ---
modules/debug.lua                       # Debug logging system (load early)
modules/NameUtil.lua                    # Canonical name normalization
modules/SlashCommands.lua               # Slash command infrastructure
modules/MessageHelpers.lua              # User messaging helpers
modules/Core.lua                        # Core addon functionality

# --- Loot Helper data model ---
modules/LootHelper/SyncProtocol.lua     # Protocol versioning and encoding
modules/LootHelper/Members.lua          # Member class
modules/LootHelper/LootLogValidators.lua # Log validation
modules/LootHelper/LootLogs.lua         # LootLog class (immutable logs)
modules/LootHelper/Profiles.lua         # Profile CRUD with stable IDs
modules/LootHelper/LootHelper.lua       # Core logic and schema migration

# --- Loot Helper sync system (18 modules, load in order) ---
modules/LootHelperSync/00_Namespace.lua    # Namespace setup
modules/LootHelperSync/01_Constants.lua    # Message types, timeouts, configs
modules/LootHelperSync/02_State.lua        # Session state management
modules/LootHelperSync/03_Metrics.lua      # Performance metrics
modules/LootHelperSync/04_SafeMode.lua     # Safe mode (pause sync on combat/demand)
modules/LootHelperSync/05_Scheduling.lua   # Timers, jitter, deferred execution
modules/LootHelperSync/06_Peers.lua        # Peer discovery from roster
modules/LootHelperSync/07_Validation.lua   # Payload validation
modules/LootHelperSync/08_Requests.lua     # Request queue management
modules/LootHelperSync/09_AdminConvergence.lua  # Pre-sync admin log exchange
modules/LootHelperSync/10_Handshake.lua    # Session handshake
modules/LootHelperSync/11_Heartbeat.lua    # Coordinator heartbeat
modules/LootHelperSync/12_LiveUpdates.lua  # Real-time log broadcasts
modules/LootHelperSync/13_Routing.lua      # Message routing logic
modules/LootHelperSync/14_HandlersControl.lua  # Control message handlers
modules/LootHelperSync/15_HandlersBulk.lua     # Bulk message handlers
modules/LootHelperSync/16_ProfileIntegration.lua  # Profile import/export
modules/LootHelperSync/17_DebugSlash.lua   # Debug slash commands
modules/LootHelperSync/18_PublicAPI.lua    # Public API (Init, Enable, StartSession)

# --- Loot Helper communication ---
modules/LootHelper/Comm.lua             # AceComm integration

# --- UI ---
modules/Settings.lua                    # Main settings panel

# --- Entry point (load last) ---
SpectrumFederation.lua                  # Event registration, initialization
```

**Adding New Files:**
1. Create under appropriate directory:
   - `SpectrumFederation/modules/` for core functionality
   - `SpectrumFederation/modules/LootHelper/` for Loot Helper features
2. Add to `.toc` after dependencies, before dependents
3. Use namespace pattern: `local addonName, SF = ...`
4. For settings sections: Create a function like `SF:CreateYourSection(panel, anchorFrame)`

## Helper Functions

## Helper Functions

**MessageHelpers (`modules/MessageHelpers.lua`):**
- `SF:PrintSuccess(message)` - Green success messages
- `SF:PrintError(message)` - Red error messages
- `SF:PrintWarning(message)` - Orange warning messages
- `SF:PrintInfo(message)` - White informational messages

**NameUtil (`modules/NameUtil.lua`):**
- `SF.NameUtil.NormalizeNameRealm(name, defaultRealm)` - Normalize to "Name-Realm" format
- `SF.NameUtil.SamePlayer(a, b)` - Case-insensitive player comparison
- `SF.NameUtil.GetSelfId()` - Get current player's canonical identifier

Use these helpers consistently throughout the addon for maintainability. See `docs/development/helper-functions.md` and `docs/development/members-class.md` for detailed documentation with examples and WoW API references.

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
SF.NameUtil  -- Name normalization (NameUtil.lua)

-- Member class (Members.lua)
SF.Member           -- Member class
SF.MemberRoles      -- Role constants (ADMIN, MEMBER)
SF.ArmorSlots       -- Armor slot constants (HEAD, SHOULDER, etc.)

-- LootLog class (LootLogs.lua)
SF.LootLog                    -- LootLog class (immutable event logs)
SF.LootLogEventTypes          -- Event type constants (PROFILE_CREATION, POINT_CHANGE, etc.)
SF.LootLogPointChangeTypes    -- Point change types (INCREMENT, DECREMENT)
SF.LootLogArmorActions        -- Armor actions (USED, AVAILABLE)

-- LootProfile class (Profiles.lua)
SF.LootProfile        -- LootProfile class

-- Sync system (LootHelperSync/*.lua)
SF.LootHelperSync     -- Sync system (Init, Enable, StartSession, EndSession)
SF.LootHelperComm     -- Communication layer (Send, RegisterHandler)
SF.SyncProtocol       -- Protocol encoding/decoding

-- SavedVariables references (set in SpectrumFederation.lua)
SF.lootHelperDB  -- Points to SpectrumFederationDB
SF.debugDB       -- Points to SpectrumFederationDebugDB
```

**SavedVariables Structure:**
```lua
-- SpectrumFederationDB (declared in .toc)
{
    profiles = {
        ["p_67890abc12def345..."] = {  -- Stable profile ID (not name-based)
            _profileId = "p_67890abc12def345...",
            _profileName = "ProfileName",
            _owner = "PlayerName-RealmName",
            _author = "PlayerName-RealmName",
            _created = timestamp,
            _modified = timestamp,
            _members = {
                ["Name-Realm"] = Member instance  -- Dictionary of Member objects
            },
            _lootLogs = { LootLog, ... },  -- Array of LootLog instances
            _authorCounters = {
                ["Name-Realm"] = 5  -- Per-author counter for log collision prevention
            },
            _adminUsers = { "Name-Realm", ... }  -- Array of admin identifiers
        }
    },
    activeProfileId = "p_67890abc12def345..."  -- Current active profile (by stable ID)
}

-- SpectrumFederationDebugDB (debug logging)
{
    enabled = false,
    logs = {},           -- Array of log entries
    maxEntries = 500
}
```

**Character Keys:** Always use `"Name-Realm"` format (e.g., `"Shadowbane-Garona"`)

**Localization:** Use `locale/enUS.lua` for all user-facing strings. Access via `ns.L` table. Add new strings to locale files. Existing code not using localization will be updated in future bug fix.

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

**Member Class Pattern (Members.lua):**
```lua
local addonName, SF = ...

-- Define constants
local MEMBER_ROLES = { ADMIN = "admin", MEMBER = "member" }
local ARMOR_SLOTS = { HEAD = "Head", SHOULDER = "Shoulder", ... }

-- Class definition
local Member = {}
Member.__index = Member

-- Constructor: use DOT notation (factory function)
function Member.new(identifier, role, class)
    local instance = setmetatable({}, Member)
    -- Initialize properties
    instance.identifier = identifier or ""
    return instance
end

-- Instance methods: use COLON notation (auto-passes self)
function Member:GetFullIdentifier()
    return self.identifier
end

function Member:ToggleEquipment(slot)
    -- Validate, toggle, call IncrementPoints() or DecrementPoints()
end

-- Export to namespace
SF.Member = Member
SF.MemberRoles = MEMBER_ROLES
SF.ArmorSlots = ARMOR_SLOTS
```

**Member Class Usage:**
```lua
-- Creating instances
local member = SF.Member.new("Shadowbane-Garona")

-- Calling instance methods
member:IncrementPoints()
local points = member:GetPointBalance()
local isAdmin = member:IsAdmin()
member:ToggleEquipment(SF.ArmorSlots.HEAD)
```

**LootLog Class Pattern (LootLogs.lua):**
```lua
local addonName, SF = ...

-- Define constants
local EVENT_TYPES = { PROFILE_CREATION = "PROFILE_CREATION", POINT_CHANGE = "POINT_CHANGE", ... }
local LOG_FORMAT_VERSION = 2

-- Class definition
local LootLog = {}
LootLog.__index = LootLog

-- Constructor: use DOT notation (factory function)
function LootLog.new(eventType, eventData, opts)
    -- opts: { author, counter, timestamp, skipPermission }
    -- Permission enforcement (skip if opts.skipPermission = true)
    -- Validation (event type, event data template, event-specific)
    -- Counter allocation from profile or opts.counter
    
    local instance = setmetatable({}, LootLog)
    instance._timestamp = timestamp      -- Private property (underscore prefix)
    instance._author = author
    instance._counter = counter
    instance._eventType = eventType
    instance._data = eventData
    instance._id = GenerateLogID(author, counter)  -- Format: "Name-Realm:123"
    return instance
end

-- Serialization constructor (for imports/sync)
function LootLog.newFromSerialized(serializedData)
    -- Deserialize CBOR/Base64, validate format version, create instance
    return instance
end

-- Instance methods: use COLON notation (auto-passes self)
function LootLog:GetID()
    return self._id
end

function LootLog:GetTimestamp()
    return self._timestamp
end

function LootLog:GetAuthor()
    return self._author
end

function LootLog:GetCounter()
    return self._counter
end

function LootLog:GetEventType()
    return self._eventType
end

function LootLog:GetEventData()
    return self._data
end

function LootLog:GetSerializedData()
    -- Serialize to CBOR, encode Base64, return string
    return encodedData
end

-- Static method: use DOT notation
function LootLog.GetEventDataTemplate(eventType)
    return templateCopy
end

-- Export to namespace
SF.LootLog = LootLog
SF.LootLogEventTypes = EVENT_TYPES
SF.LootLogPointChangeTypes = POINT_CHANGE_TYPES
SF.LootLogArmorActions = ARMOR_ACTIONS
```

**LootLog Class Usage:**
```lua
-- Creating logs
local eventType = SF.LootLogEventTypes.POINT_CHANGE
local eventData = SF.LootLog.GetEventDataTemplate(eventType)
eventData.member = "Healer-Garona"
eventData.change = SF.LootLogPointChangeTypes.INCREMENT

local log = SF.LootLog.new(eventType, eventData)
if log then
    -- Success: log created with auto-generated ID (author:counter)
    table.insert(profile.logs, log)
end

-- Accessing log data (use getters, not direct property access)
local id = log:GetID()             -- "Healer-Garona:1"
local timestamp = log:GetTimestamp()
local author = log:GetAuthor()
local counter = log:GetCounter()
local eventType = log:GetEventType()
local data = log:GetEventData()

-- Serialization for sync
local serialized = log:GetSerializedData()  -- Base64-encoded CBOR

-- Deserialization
local receivedLog = SF.LootLog.newFromSerialized(serialized)

-- Profile creation log (skip permission check)
local opts = { skipPermission = true }
local profileLog = SF.LootLog.new(
    SF.LootLogEventTypes.PROFILE_CREATION,
    { profileId = "MyProfile-UniqueID" },
    opts
)
```

**Profile Functions (LootProfiles.lua):**
```lua
local addonName, SF = ...

function SF:CreateNewLootProfile(profileName)
    -- Validation, creation logic
    if SF.Debug then SF.Debug:Info("PROFILES", "Created new profile '%s'", profileName) end
end

function SF:SetActiveLootProfile(profileName)
    SF.lootHelperDB.activeProfile = profileName
    if SF.Debug then SF.Debug:Info("PROFILES", "Set active profile to '%s'", profileName) end
end

function SF:DeleteProfile(profileName)
    SF.lootHelperDB.profiles[profileName] = nil
    if SF.Debug then SF.Debug:Info("PROFILES", "Deleted profile '%s'", profileName) end
end
```

**Messaging (use everywhere):**
```lua
-- Success messages
SF:PrintSuccess("Profile created successfully!")

-- Error messages
SF:PrintError("Profile name cannot be empty!")

-- Warning messages
SF:PrintWarning("Profile has not been used in 30 days")

-- Info messages
SF:PrintInfo("Addon loaded. Type /sf to open settings.")
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

**Settings UI Structure (Settings.lua + LootHelper/Settings.lua):**
```lua
-- Main settings panel (Settings.lua)
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

-- Section file (LootHelper/Settings.lua)
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
3. **`pr-beta-docs-sync.yml`** - Documentation sync for beta PRs:
   - Automatically appears on PRs to beta branch
   - Requires maintainer approval before running (via `documentation-sync` environment)
   - Analyzes code changes vs beta branch
   - Uses GitHub Copilot API to suggest documentation updates
   - Updates MkDocs documentation (`.github/scripts/analyze_docs_changes.py`)
   - Updates copilot instructions (`.github/scripts/analyze_copilot_instructions.py`)
   - Creates PR with suggested changes targeting the feature branch
   - Comments on original PR with link to documentation PR
   - **Trigger**: Automatic on `pull_request_target` to beta (requires approval) OR manual via workflow_dispatch with PR number
   - **Environment**: `documentation-sync` - Must be configured in repository settings with required reviewers
   - **Purpose**: Keep documentation in sync with code changes before merge
   - **Setup**: See `.github/ENVIRONMENT_SETUP.md` for configuration instructions
4. **`post-merge-beta.yml`** - Automated beta releases after merge:
   - Sanity checks
   - Blizzard API query for beta Interface version
   - Changelog update (`.github/scripts/update_changelog.py`)
   - README badge update
   - Beta release creation (`.github/scripts/publish_release.py`)
5. **`promote-beta-to-main.yml`** - Manual promotion workflow (admin only):
   - Merges beta → main with special CHANGELOG/README handling
   - Removes `-beta` suffix from version
   - Updates Interface version using Blizzard live API
   - Updates changelog and README
   - Deploys MkDocs documentation
   - Creates stable release
   - Fast-forwards beta to main
   - Supports dry-run mode
6. **`rollback-release.yml`** - Emergency rollback for failed promotions (admin only)

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
- Access via `SF.lootHelperDB` (never direct `SpectrumFederationDB`)
- Profile data: `SF.lootHelperDB.profiles[profileId]` (using stable profile IDs)
- Active profile: `SF.lootHelperDB.activeProfileId`

**UI Components:**
- Create main panel in `modules/Settings.lua`
- Create UI sections in `modules/` directory
- Store UI elements in SF namespace (e.g., `SF.LootProfileDropdown`)
- Use `UIParent` as parent for main frames
- Banner scales to 90% of panel width with aspect ratio preserved

## Documentation

**MkDocs (docs/):**
- Material theme, auto-deploys to GitHub Pages
- Run locally: `pip install -r requirements-docs.txt && mkdocs serve`
- Add feature docs in `docs/` when adding user-facing features

**MkDocs Markdown Formatting:**
- **CRITICAL**: Always add a blank line before and after bullet lists and numbered lists
- MkDocs requires blank lines for proper list rendering (VS Code preview may not show this)
- Example:
  ```markdown
  **Parameters**:
  
  - `param1` - Description
  - `param2` - Description
  
  **Process**:
  
  1. First step
  2. Second step
  ```
- Without blank lines, bullets will render as inline text with dashes

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
- ✅ Always access via `SF.lootHelperDB` and `SF.debugDB`
- ✅ Always initialize in `SF:InitializeDatabase()`
- ✅ Profile data stored in `SF.lootHelperDB.profiles`

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
│   ├── Debug.lua             # Logging system
│   ├── Core.lua              # Core functionality
│   ├── NameUtil.lua          # Name normalization
│   ├── MessageHelpers.lua    # User messaging
│   ├── SlashCommands.lua     # Slash commands
│   ├── Settings.lua          # Main settings panel
│   ├── LootHelper/
│   │   ├── SyncProtocol.lua  # Protocol versioning
│   │   ├── Comm.lua          # AceComm layer
│   │   ├── Members.lua       # Member class
│   │   ├── LootLogValidators.lua  # Log validation
│   │   ├── LootLogs.lua      # LootLog class
│   │   ├── Profiles.lua      # Profile CRUD
│   │   └── LootHelper.lua    # Core logic + migration
│   └── LootHelperSync/
│       ├── 00_Namespace.lua through 18_PublicAPI.lua
│       └── # Session sync system (18 files)
├── Libs/
│   ├── LibStub/              # Library loader
│   ├── CallbackHandler/      # Event callbacks
│   └── AceComm/              # Addon messaging
├── locale/
│   └── enUS.lua              # Localization
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