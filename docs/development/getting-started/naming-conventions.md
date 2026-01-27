# Naming Conventions

To ensure code consistency and readability across the **Spectrum Federation** codebase, we adhere to the standard Lua and World of Warcraft development conventions.

## 1. Variables & Table Keys

We use **camelCase** for local variables, function arguments, and database keys.

* **Why:** It clearly distinguishes internal data from Blizzard's API (which uses PascalCase) and Global Constants (which use UPPER_CASE).

**Examples:**

```lua
-- Good
local playerName = UnitName("player")
local activeProfile = SF.db.activeProfile
local lootProfiles = {}

-- Bad
local PlayerName = ...     (Looks like a Global/API)
local active_profile = ... (Not standard for WoW Lua)
```

### Database Schema

All keys inside the `SpectrumFederationDB` SavedVariables table must use **camelCase**.

```lua
SpectrumFederationDB = {
    activeProfile = "Raid Night",  -- Correct
    lootProfiles = {},             -- Correct
    Owner_Name = "Player"          -- Incorrect (Avoid Snake_Case)
}
```

## 2. Global Objects & Public Functions

We use **PascalCase** for global objects, namespace methods, and file names.

* **Why:** This mimics the native World of Warcraft API (e.g., `CreateFrame`, `UnitName`), making our "Public" functions feel like a natural extension of the game engine.

**Examples:**

```lua
-- Namespace Methods
function SF:InitializeDatabase() ... end
function SF:CreateSettingsUI() ... end

-- Global Variables
SpectrumFederationDB = {}
```

## 3. Constants

We use **UPPER_SNAKE_CASE** for static constants and configuration variables.

* **Why:** It immediately signals to the developer that this value is hardcoded and should not be modified during runtime.

**Examples:**

```lua
local MAX_PROFILES = 10
local DEFAULT_ICON_SIZE = 32

-- Global Slash Command Keys
SLASH_SPECFED1 = "/sf"
```

## 4. File Structure

File names should use **PascalCase** (or kebab-case for specific UI modules if preferred, but consistency is key).

* `SpectrumFederation.lua` (Core)
* `modules/SettingsUI.lua` (or `settings-ui.lua` if sticking to the current pattern)

## Summary Table

| Type | Convention | Example |
| :--- | :--- | :--- |
| **Local Variables** | `camelCase` | `local myFrame` |
| **Function Args** | `camelCase` | `function(name, realm)` |
| **Database Keys** | `camelCase` | `db.lootProfiles` |
| **Public Functions** | `PascalCase` | `SF:CreateProfile()` |
| **Global Objects** | `PascalCase` | `SpectrumFederationDB` |
| **Constants** | `UPPER_SNAKE_CASE` | `MAX_PROFILE_COUNT` |