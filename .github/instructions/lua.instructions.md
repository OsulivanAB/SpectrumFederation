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
- **Packaged Lua/behavior changes require a TOC version bump** when
  `release_required` applies — update `## Version:` in
  `SpectrumFederation/SpectrumFederation.toc` and keep packaged child TOC
  Version/Interface values in lockstep:
  - On **beta branch**: keep the `-beta.N` suffix and increment N by 1 (e.g., `0.5.0-beta.3` → `0.5.0-beta.4`). A version without `-beta.N` is **invalid** on beta.
  - On **main branch**: bump the SemVer component (patch/minor/major) and drop the `-beta.N` suffix.
  - Instruction/docs/infra-only changes do not require a bump when the TOC
    format is already valid. A repair iteration does not automatically require
    another increment when the PR version is already valid for delivery. See
    root `AGENTS.md` Packaging And Versioning and
    `.github/instructions/toc-version.instructions.md`.
- Prefer Blizzard-safe UI integration:
  - use `hooksecurefunc` instead of replacing Blizzard functions
  - guard UI changes during combat (`InCombatLockdown()`), and defer if necessary
- Debugging:
  - use `SF.Debug` (see `SpectrumFederation/modules/debug.lua`)
  - avoid chat spam for diagnostics
- User-facing messages should use `SF:PrintSuccess/Error/Warning/Info` when appropriate (see `modules/MessageHelpers.lua`).
- Proactively guard user-visible output against repetition/spam, especially on recurring paths (heartbeats, timers, sync, retries). Prefer state-transition messaging, deduplication, or meaningful-change detection over arbitrary cooldowns. Canonical guidance: `SpectrumFederation/AGENTS.md` (User-visible messaging → Anti-spam and repetition).
- Inspect existing architecture, callers, and lifecycle before assuming a Lua change is local or safe.

## Client Stability

Preventing World of Warcraft client crashes, freezes, severe UI hangs, runaway execution, and long-session performance degradation is one of the highest priorities when reviewing, auditing, designing, or modifying addon runtime code. This is an engineering requirement, not a generic reminder to consider performance.

Addon Lua runs primarily on the game's UI thread. Work does not need to be literally infinite to freeze the client.

- **Idle means idle:** a visible page with no state change, user interaction, or intentionally scheduled task should not continuously rebuild, reflow, inspect, reconstruct databases, schedule refreshes, allocate objects, or broadcast sync traffic unless there is an intentional documented reason.
- Repeated open/close, enable/disable, page switches, and resizes must not accumulate listeners, callbacks, timers, tickers, frames, textures, deferred work, inspect requests, or sync work.
- Queues, retries, and deferred work should drain to empty and become idle after the producer stops.
- Bound retry cadence and lifecycle; do not silently discard a required unfinished obligation solely to impose a fixed retry count, and do not retry forever without a remaining obligation. Timeout is not proof that an external side effect did not happen.
- Caches need authoritative inputs, scoped invalidation, incomplete/stale-data handling, and tests for both reuse and reevaluation.
- Watch for unbounded loops, re-entrancy, `OnSizeChanged`/layout feedback, leftover timers, addon-message storms, inspect retry storms, high-frequency rebuilds, and growing allocations.
- Shared Settings/UI (`Section`, `PageBuilder`, Controls, ScrollFrames, layout helpers) needs extra re-entrancy review and consumer inspection.
- Prefer tests that assert bounded execution, convergence, and relevant lifecycle sequences, not merely that no Lua error occurred or that a helper name exists.
- Unexpected errors should remain visible via WoW's error handler / BugGrabber. Protect cleanup without swallowing defects; neither swallowing nor rethrowing before required cleanup is complete recovery.

Canonical guidance: `SpectrumFederation/AGENTS.md` and `.cursor/rules/addon-runtime.mdc`.
