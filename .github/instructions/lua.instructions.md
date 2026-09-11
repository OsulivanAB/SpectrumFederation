---
applyTo: "SpectrumFederation/**/*.lua,SpectrumFederation_CursedSurgeTracker/**/*.lua,SpectrumFederation_RCLootCouncilIntegration/**/*.lua"
---

# Lua (WoW Addon) Instructions

- Target runtime is **WoW Lua 5.1**. Avoid Lua 5.2+ features and any `io`/`os` usage.
- Avoid globals. Use the repo pattern:
  - `local addonName, SF = ...`
  - attach public APIs/modules onto `SF`
- Keep changes minimal and localized to the feature you are implementing.
- Add new Lua files to the owning addon's TOC in correct load order (deps before dependents). Child-addon files go in that child's TOC, not the parent TOC.
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
- Inspect existing architecture, callers, and lifecycle before assuming a Lua change is local or safe.

## Client Stability

Preventing World of Warcraft client crashes, freezes, severe UI hangs, runaway execution, and long-session performance degradation is one of the highest priorities when reviewing, auditing, designing, or modifying addon runtime code. This is an engineering requirement, not a generic reminder to consider performance.

Addon Lua runs primarily on the game's UI thread. Work does not need to be literally infinite to freeze the client.

- **Idle means idle:** a visible page with no state change, user interaction, or intentionally scheduled task should not continuously rebuild, reflow, inspect, reconstruct databases, schedule refreshes, allocate objects, or broadcast sync traffic unless there is an intentional documented reason.
- Repeated open/close, enable/disable, page switches, and resizes must not accumulate listeners, callbacks, timers, tickers, frames, textures, deferred work, inspect requests, or sync work.
- Queues, retries, and deferred work should drain to empty and become idle after the producer stops.
- Watch for unbounded loops, re-entrancy, `OnSizeChanged`/layout feedback, leftover timers, addon-message storms, inspect retry storms, high-frequency rebuilds, and growing allocations.
- Shared Settings/UI (`Section`, `PageBuilder`, Controls, ScrollFrames, layout helpers) needs extra re-entrancy review and consumer inspection.
- Prefer tests that assert bounded execution and convergence, not merely that no Lua error occurred.
- Unexpected errors should remain visible via WoW's error handler / BugGrabber. `pcall` is appropriate for cleanup; do not hide severe defects.

Canonical guidance: `SpectrumFederation/AGENTS.md` and `.cursor/rules/addon-runtime.mdc`.
