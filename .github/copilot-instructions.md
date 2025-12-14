Copilot Instructions for SpectrumFederation
===========================================

These instructions tell GitHub Copilot how this repository is structured and how it should generate code and configuration for the **SpectrumFederation** World of Warcraft addon.

---

Project Overview
----------------

SpectrumFederation is a **World of Warcraft addon** for the Spectrum Federation guild on Garona.

It is:

-   Written in **Lua 5.1** (WoW's Lua version)

-   Packaged as a standard WoW addon folder (`SpectrumFederation/`)

-   Distributed via **GitHub releases**, with zip layout compatible with **WowUp** and **CurseForge**

### Repository Layout (top level)

-   `SpectrumFederation/` -- Main addon folder (what gets zipped and placed in `Interface/AddOns/`)

-   `.github/workflows/` -- CI and release workflows

    -   `validate-packaging.yml` -- validates zip layout + version bump

    -   `linter.yml` -- Lua and YAML linting

    -   `release.yml` -- auto-tagging and release packaging

-   `.github/scripts/` -- Helper shell scripts used by workflows

    -   `validate-addon-package.sh` -- WowUp/CurseForge compatibility checks

    -   `check-version-bump.sh` -- ensures addon version is bumped in PRs

-   `.devcontainer/` -- Dev container definition and Blizzard UI setup script

-   `BlizzardUI/` -- **Generated locally** by the devcontainer for reference only (retail + beta UI sources)

    -   This folder is **git-ignored and must never be committed**

---

Branch & Release Model
----------------------

Assumptions for Copilot:

-   `main` -- **Stable / Live** version of the addon

-   `beta` -- **Beta / pre-release** version of the addon

Rules:

-   No direct pushes to `main` or `beta` -- all changes go through feature branches and Pull Requests.

-   Every PR into `main` or `beta` must:

    -   Pass **luacheck** (Lua linting)

    -   Pass **addon packaging validation** (WowUp/CurseForge layout)

    -   Include a **version bump** in `SpectrumFederation/SpectrumFederation.toc` (`## Version:`)

Tags and GitHub releases are created automatically by the release workflow.\
Copilot should **not** suggest manually creating tags/releases unless explicitly requested.

---

WoW Addon Fundamentals
----------------------

### TOC File: `SpectrumFederation/SpectrumFederation.toc`

This file is the addon manifest and is critical for both loading and packaging.

Important fields:

-   `## Interface:`

    -   Numeric interface value (e.g. `120000` for 12.0.0)

    -   Must be updated when targeting new WoW patches

-   `## Version:`

    -   Addon version (e.g. `0.1.0`, `0.1.0-beta.1`)

    -   **Must be updated** for any behavior change merged into `main` or `beta`

    -   CI will fail PRs that don't bump it

-   File list:

    -   Files listed here load **in order**; core logic before UI where possible.

When Copilot adds a new Lua module:

-   Place it under `SpectrumFederation/` (usually in `modules/` or `locale/`).

-   Add it to the `.toc` in the correct order.

### Namespace Pattern

All addon Lua files should use the standard Wow addon namespace pattern:

```lua
local addonName, ns = ...
```

Guidelines:

-   Use `ns` to share state between files:

    -   `ns.L` -- localization table

    -   `ns.core` -- core functions/utilities

    -   `ns.ui` -- UI-related helpers

-   Avoid creating real globals unless required (e.g., saved variables or WoW requires it).

### Module Structure

Inside `SpectrumFederation/`:

-   `SpectrumFederation.lua`

    -   Entry point

    -   Creates the main frame

    -   Registers events (e.g. `PLAYER_LOGIN`)

    -   Delegates work to `ns.core`, `ns.ui`, etc.

-   `modules/core.lua`

    -   Core logic, data handling, helpers

-   `modules/ui.lua`

    -   UI elements, frames, visuals

-   `locale/enUS.lua`

    -   English localization strings in `ns.L`

When Copilot creates new features:

-   Prefer putting non-UI logic in `modules/core.lua`.

-   Prefer putting visual / frame logic in `modules/ui.lua`.

-   Add new user-facing strings in `locale/enUS.lua`.

---

CI & Workflows (What Copilot Should Respect)
--------------------------------------------

### 1\. Version Management

Every merge into `main` or `beta` must bump:

-   `## Version:` in `SpectrumFederation/SpectrumFederation.toc`

Version style:

-   Stable: `0.0.2`, `0.0.3`, etc.

-   Beta: `0.0.3-beta.1`, `0.0.3-beta.2`, etc.

Script: `.github/scripts/check-version-bump.sh`

-   Compares the version in the PR with the version in the target branch (`main` or `beta`).

-   Fails the PR if the version did not change or went backwards.

Copilot should not remove or weaken this check without explicit instruction.

### 2\. Linting (Lua and YAML)

Workflow: `.github/workflows/linter.yml`\
Configs: `.luacheckrc` (Lua), yamllint uses relaxed mode (YAML)

-   Runs `luacheck` on the `SpectrumFederation/` directory.

-   Runs `yamllint` on the `.github/` directory.

-   Uses **Lua 5.1** rules.

-   Lua: Warnings are allowed; **errors** (syntax, invalid config) fail the build.

-   YAML: Uses relaxed configuration; validates syntax and basic formatting.

Guidelines for Copilot:

-   Use valid Lua 5.1 syntax only (no Lua 5.3/5.4 features).

-   Minimize new globals; if needed, declare WoW API globals or saved variables in `.luacheckrc` instead of disabling checks everywhere.

-   Ensure YAML files in `.github/` end with a newline and have valid syntax.

### 3\. Addon Packaging (WowUp + CurseForge)

Script: `.github/scripts/validate-addon-package.sh`\
Called from a workflow like `validate-packaging.yml`.

Rules it enforces:

-   The **zip root** must contain **exactly one folder**: `SpectrumFederation/`

-   Inside that folder:

    -   There must be a TOC file named exactly `SpectrumFederation.toc`

    -   The TOC must have a valid `## Interface:` line (numeric, commas allowed)

Copilot should ensure any packaging logic it writes follows this layout.

### 4\. Release Pipeline

Workflow: `.github/workflows/release.yml`

Behavior:

1.  Triggered on pushes/merges to `main` and `beta`.

2.  Reads `## Version:` from the TOC.

3.  Compares to previous commit:

    -   If unchanged → skip release.

    -   If changed → proceed.

4.  Defines/validates tag: `v<TOC version>` (e.g. `v0.1.0`, `v0.1.0-beta.1`).

5.  Creates or reuses that tag (without moving existing tags).

6.  Builds `SpectrumFederation-<version>.zip` with `SpectrumFederation/` at the root.

7.  Creates or updates the GitHub Release:

    -   Pre-release if beta (`beta` branch or `-beta` in version).

    -   Normal release otherwise.

Copilot should assume this is the **single source of truth** for tag + release creation.

---

Dev Environment & BlizzardUI
----------------------------

### Devcontainer

The devcontainer (`.devcontainer/`) sets up a consistent environment:

-   OS: Ubuntu devcontainer

-   Tools:

    -   `lua5.1`, `luarocks`, `luacheck`

    -   `git`, `curl`, `zip`, `openssh-client`

-   VS Code extensions are recommended:

    -   `LuaLS.lua-language-server`

    -   `ketho.wow-api`

    -   GitHub Copilot and Copilot Chat

### Blizzard UI Source (Live & Beta)

Script: `.devcontainer/setup-blizzard-ui.sh`

-   On container start, it clones/updates `BlizzardUI/`:

    -   `BlizzardUI/live/` -- Retail UI

    -   `BlizzardUI/beta/` -- Beta/PTR UI

-   This folder is for **reference only**, ignored by git.

Copilot should:

-   Treat `BlizzardUI/` as read-only example code.

-   Not create runtime dependencies on `BlizzardUI/` paths.

-   Use it to infer patterns/APIs but not copy entire files.

---

Testing (In-Game)
-----------------

Copilot should assume changes are tested by:

1.  Copying `SpectrumFederation/` to:

    -   `_retail_/Interface/AddOns/SpectrumFederation/` (live)

    -   `_beta_/Interface/AddOns/SpectrumFederation/` (beta)

2.  Launching the game, enabling the addon.

3.  Running `/reload` after changes.

4.  Enabling script errors: `/console scriptErrors 1`.

5.  Checking for addon load messages and Lua errors in chat.

---

Coding Conventions for Copilot
------------------------------

### Event Handling

Use a frame-based dispatcher and delegate logic:

```lua
local addonName, ns = ...

local frame = CreateFrame("Frame")

frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if ns.core and ns.core.OnPlayerLogin then
            ns.core.OnPlayerLogin(...)
        end
    end
end)
```

-   Event handlers should live in `SpectrumFederation.lua` or in specific modules via `ns.core`, `ns.ui`.

### Localization

Put user-facing strings in `locale/enUS.lua` on `ns.L`:

```lua
local addonName, ns = ...
local L = ns.L

L["ADDON_LOADED_MSG"] = "Spectrum Federation loaded successfully!"
-- Usage: print(L["ADDON_LOADED_MSG"])
```

When generating new UI text, Copilot should:

-   Add a new key/value in `locale/enUS.lua`.

-   Use `ns.L["KEY"]` when printing or showing text.

### Style

-   WoW API: PascalCase / CamelCase (`CreateFrame`, `SetScript`, etc.).

-   Local variables: `snake_case` or `lowerCamelCase`, consistent within a file.

-   Minimize global variables; prefer `ns.something`.

### Chat Output

Use colored output prefixes where appropriate:

```lua
print("|cff00ff00Spectrum Federation|r loaded successfully!")
```

---

BlizzardUI Usage Guidelines
---------------------------

When using BlizzardUI as reference:

-   Look up similar systems under:

    -   `BlizzardUI/live/Interface/AddOns/`

    -   `BlizzardUI/beta/Interface/AddOns/`

-   Copy **patterns and small snippets**, not entire files.

-   Never require BlizzardUI's presence at runtime.

-   Never commit `BlizzardUI/` to git.

---

Pitfalls Copilot Should Avoid
-----------------------------

-   Forgetting to bump `## Version` in `SpectrumFederation.toc` when merging to `main` or `beta`.

-   Adding new modules without adding them to the `.toc` file.

-   Using Lua 5.3/5.4 features (no bitwise operators, `goto`, etc. -- WoW is **Lua 5.1**).

-   Changing the zip structure so the addon folder is not at the root.

-   Creating unnecessary globals instead of using `ns`.

-   Modifying or depending on `BlizzardUI/` in runtime code.

-   Removing or breaking:

    -   `.github/scripts/check-version-bump.sh`

    -   `.github/scripts/validate-addon-package.sh`

    -   `.github/workflows/linter.yml`

    -   `.github/workflows/validate-packaging.yml`

    -   `.github/workflows/release.yml`

---

By following these rules, Copilot will:

-   Generate code that fits SpectrumFederation's architecture.

-   Keep releases compatible with both WowUp and CurseForge.

-   Work smoothly with your devcontainer and BlizzardUI reference setup.

-   Respect your CI and versioning requirements.


