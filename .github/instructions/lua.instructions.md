---
applyTo: "SpectrumFederation/**/*.lua"
---

# Lua (WoW Addon) Instructions

- Target runtime is **WoW Lua 5.1**. Avoid Lua 5.2+ features and any `io`/`os` usage.
- Avoid globals. Use the repo pattern:
  - `local addonName, SF = ...`
  - attach public APIs/modules onto `SF`
- Keep changes minimal and localized to the feature you are implementing.
- Add new Lua files to `SpectrumFederation/SpectrumFederation.toc` in correct load order (deps before dependents).
- Prefer Blizzard-safe UI integration:
  - use `hooksecurefunc` instead of replacing Blizzard functions
  - guard UI changes during combat (`InCombatLockdown()`), and defer if necessary
- Debugging:
  - use `SF.Debug` (see `SpectrumFederation/modules/debug.lua`)
  - avoid chat spam for diagnostics
- User-facing messages should use `SF:PrintSuccess/Error/Warning/Info` when appropriate (see `modules/MessageHelpers.lua`).
