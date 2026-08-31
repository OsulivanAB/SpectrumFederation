# SpectrumFederation – Agent Notes (Addon Code)

These notes apply when changing files under `SpectrumFederation/`.

## Branch policy reminder
- Copilot PRs must target `beta` (work branches start from `beta`).
- `main` is release-only.

## Scope control (prevent creep)
- Keep PRs **small and targeted**. Do not refactor unrelated systems “while you’re here.”
- Do not add new third‑party libraries unless explicitly requested.
- Prefer extending existing patterns over inventing new frameworks.

## WoW Lua constraints (hard rules)
- Lua runtime is **Lua 5.1** (WoW embedded). Avoid 5.2+ syntax/features.
- No `io`, `os`, filesystem access, sockets, or external processes (WoW sandbox).
- Avoid UI taint and protected frame issues:
  - Prefer `hooksecurefunc` over overwriting Blizzard functions.
  - Avoid modifying protected UI in combat; guard with `InCombatLockdown()` when relevant.

## Where to put code
- Entry point / initialization / events: `SpectrumFederation/SpectrumFederation.lua`
- Core helpers (time/version/etc): `SpectrumFederation/modules/Core.lua`
- Player/name normalization: `SpectrumFederation/modules/NameUtil.lua`
- User messages: `SpectrumFederation/modules/MessageHelpers.lua`
- Debug logger: `SpectrumFederation/modules/debug.lua` (`SF.Debug`)
- Settings:
  - Schema/Store/Apply: `SpectrumFederation/modules/Settings/`
  - Settings UI framework + pages: `SpectrumFederation/modules/UI/Settings/`

## Adding a new setting (correct, minimal workflow)
When you need a new toggle/option:
1. **Schema:** add the setting definition to `modules/Settings/Schema.lua`.
   - Use a stable key name (prefer `snake_case`).
   - Add a default value.
   - Place it under the appropriate section (e.g., **General**).
2. **Storage:** follow existing patterns in `modules/Settings/Store.lua` (many settings are automatic—copy what existing settings do).
3. **Apply behavior:** ensure the setting actually affects runtime behavior.
   - Prefer handling in the feature module, but use `modules/Settings/Apply.lua` if that’s the established pattern.
4. **UI:** render it in the Settings UI (typically `modules/UI/Settings/Pages/General.lua` for General).
   - Use the existing renderer, registry, and standalone window—do not create a second UI system.
   - New pages use `categoryId` for the sidebar category. Legacy `parentId` still works. Categories with two or more content pages appear as tabs, not nested sidebar rows.
5. **Schema migrations:** avoid unless strictly necessary. If needed, keep it tiny and backward-compatible.

## Debug logging (required for new features)
- Use `SF.Debug` for diagnostic output.
- Prefer existing call patterns:
  - Search for existing `SF.Debug:` call sites and mirror the signature.
  - The debug module supports a core `Log(level, category, message, ...)` style; wrapper helpers may exist (e.g., `Info/Warn/Error/Verbose`) — reuse what the codebase already uses.
- Log:
  - User-triggered actions and feature start/stop (INFO)
  - Recoverable problems (WARN)
  - Unexpected nils / failed API calls / hard failures (ERROR)
- Do not log in hot paths (tight loops, per-frame handlers).

## User-visible messaging
- Prefer `modules/MessageHelpers.lua` helpers (`SF:PrintSuccess/Error/Warning/Info`) when you need to tell the user something.
- Do not spam chat for debugging (use `SF.Debug` instead).

## Localization
- If the repo has `locale/enUS.lua` and `ns.L`, use it for new user-facing strings.
- If existing code is not fully localized yet, keep your additions consistent with the existing direction (don’t introduce a third pattern).

## Packaging + versioning
- **Any new Lua file must be listed in** the TOC of the addon that owns it (`SpectrumFederation.toc` or a child-addon TOC).
- Parent TOC files must not load child-addon Lua or XML.
- **Any behavior/UI/settings change must bump** `## Version:` in `SpectrumFederation/SpectrumFederation.toc` and keep any packaged child TOC on the same version.

## Validation checklist (do these before declaring “done”)
- `python3 .github/scripts/lint_all.py`
- `/reload` in-game without errors.
- Verify the new setting appears (when applicable) and toggling it changes behavior as intended.
- Settings navigation changes: `python -m pytest tests/test_settings_navigation.py`
