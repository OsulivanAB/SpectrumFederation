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
- **Every Lua change requires a TOC version bump** — update `## Version:` in `SpectrumFederation/SpectrumFederation.toc`:
  - On **beta branch**: keep the `-beta.N` suffix and increment N by 1 (e.g., `0.5.0-beta.3` → `0.5.0-beta.4`). A version without `-beta.N` is **invalid** on beta.
  - On **main branch**: bump the SemVer component (patch/minor/major) and drop the `-beta.N` suffix.
  - Do this **before finalizing** — it is a PR blocker if missing.
- Prefer Blizzard-safe UI integration:
  - use `hooksecurefunc` instead of replacing Blizzard functions
  - guard UI changes during combat (`InCombatLockdown()`), and defer if necessary
- Debugging:
  - use `SF.Debug` (see `SpectrumFederation/modules/debug.lua`)
  - avoid chat spam for diagnostics
- User-facing messages should use `SF:PrintSuccess/Error/Warning/Info` when appropriate (see `modules/MessageHelpers.lua`).
