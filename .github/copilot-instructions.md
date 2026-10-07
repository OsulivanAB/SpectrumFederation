# SpectrumFederation – Copilot Instructions

These instructions guide GitHub Copilot coding agent and VS Code Agent Mode for this repo.

## Non‑negotiables
- **Versioning follows deterministic release classification — not a blanket bump on every PR:**
  - Packaged addon behavior, UI, settings, runtime Lua/XML/assets, or `pkgmeta.yaml` changes (`release_required` from `.github/scripts/classify_promotion_scope.py`) **MUST** bump `## Version:` in `SpectrumFederation/SpectrumFederation.toc` and keep packaged child TOC Version/Interface values in lockstep.
  - **beta target:** version must be `X.Y.Z-beta.N` and ahead of the PR base (and ahead of `main` when that comparison applies). Example: `0.4.0-beta.7` → `0.4.0-beta.8`. A plain SemVer like `0.4.0` is **never** valid on beta.
  - **main target:** bump SemVer (patch/minor/major as appropriate); drop the `-beta.N` suffix.
  - Instruction-only, docs-only, workflow/script, or other infra changes that do **not** alter packaged addon contents do **not** require a version bump when the TOC version is already valid for the target branch. Zip-excluded files such as `*/AGENTS.md` are not packaged releases.
  - A repair iteration does not automatically require another version increment when the PR's version is already valid and ahead of the base for delivery.
  - When a bump is required, check the TOC early and include it before finalizing. Trust `.github/scripts/check_version_bump.py` and `classify_promotion_scope.py` over outdated prose.
- **Do not bypass CI:** never change workflows/checks to “make it green.”
- **WoW Lua only:** Lua 5.1 sandbox (no `io`, `os`, Lua 5.2+ features).
- **Inspect before assuming:** read existing architecture, callers, lifecycle, and persisted data before treating a change as local or safe.
- **Change contract for risky work:** shared/persisted state, caches, queues, retries, async side effects, sync/protocol, shared UI, or recurring runtime work needs a brief authority/guarantee/dependencies/lifecycle/evidence check before implementation. Ordinary local fixes do not. See root `AGENTS.md`.
- **Client stability is a top runtime priority:** preventing WoW client crashes, freezes, severe UI hangs, runaway execution, and long-session degradation is an engineering requirement whenever reviewing, auditing, designing, or modifying addon runtime code. Addon Lua runs on the UI thread; work does not need to be infinite to freeze the client. Idle features should become idle. Repeated lifecycle operations and queues must converge. Caches need scoped invalidation and reuse/reevaluation tests. Retries must not silently abandon required unfinished obligations. Shared Settings/UI infrastructure needs extra re-entrancy review. Prefer behavioral lifecycle tests for layout/timer/listener/queue/sync/cache/retry changes. Unexpected errors should remain visible via the normal error handler / BugGrabber; protect cleanup without swallowing defects. Full guidance: `SpectrumFederation/AGENTS.md` and `.cursor/rules/addon-runtime.mdc`. This does not replace compatibility, functionality preservation, or minimal targeted changes.

## Branch policy (Copilot + agents)
- **All Copilot coding agent work MUST start from `beta` and open a PR targeting `beta`.**
- Do not open PRs to `main`. `main` is release-only.
- When starting an agent task (Agents tab/panel or “Assign to Copilot”), **select `beta` as the base branch**.

## Project layout (where things go)
- Runtime addon code is under `SpectrumFederation/` (this is what gets packaged).
- Load order matters. **Any new Lua file must be added to** `SpectrumFederation/SpectrumFederation.toc` in dependency order.
- Use the shared namespace pattern:
  - `local addonName, SF = ...`
  - attach addon APIs/modules to `SF` (avoid globals)

## Settings + Debugging
- Settings system:
  - Schema/Store/Apply: `SpectrumFederation/modules/Settings/`
  - Settings UI: `SpectrumFederation/modules/UI/Settings/`
- Use the built-in debug logger (`SpectrumFederation/modules/debug.lua`) instead of chat spam.
- User-facing chat output is opt-in: do not add new normal WoW chat messages unless the task/issue explicitly asks for them or the user explicitly approves. See `SpectrumFederation/AGENTS.md` (User-visible messaging).
- Proactively evaluate user-visible output for repetition/spam risk on recurring paths (heartbeats, timers, sync, retries). See `SpectrumFederation/AGENTS.md` (User-visible messaging → Anti-spam and repetition).
- Prefer reusing existing settings controls and renderers; don’t introduce a second settings framework.

## Validation (always do before finalizing)
Select checks from the canonical map in root `AGENTS.md` (Validation By Change Area). At minimum for addon/workflow/CI script changes:
```sh
python3 .github/scripts/lint_all.py
```
Prefer behavioral sequence evidence for stateful fixes over source-string-only assertions. Prefer fail-then-pass regression demonstration when practical. Do not fabricate Retail QA. "Awaiting human Retail QA" is a legitimate handoff state.

## Pull request descriptions
- **Always use the repository PR template** at `.github/pull_request_template.md` when creating or updating a PR description.
- At the start of each task, read `.github/pull_request_template.md` and draft PR updates against that structure from the beginning.
- Preserve the template's section headings, order, checklist items, and prompts; do not replace the template with a custom format.
- Copy the template structure into the PR body and fill it in; do **not** submit only a summary, only a checklist, or any alternate layout.
- Do **not** wrap the PR title or PR description in custom XML/HTML tags such as `<pr_title>` or `<pr_description>`.
- If any tool temporarily overwrites the PR description while reporting progress, restore the full repository PR template before finishing the task.
- Fill out every section **to the best of your ability** using the information available from the task, code changes, validation, and testing performed.
- If a section does not apply or you do not have the information, keep the template section and state that clearly instead of omitting it.
- When a tool asks for a PR title/description, first read the template and then format the response to match it.
- **Never check `I have tested these changes in-game`.** That box is human-owned after Retail QA. You MAY check **In-game testing is not applicable to this change** only when there are no packaged addon/runtime changes, except allowlisted TOC metadata or files the release zip demonstrably excludes (`*/AGENTS.md`). Do not infer harmlessness from extension. Unknown packaged files and assets require human QA. Always check **WoW Client Type → Retail** (product target, not in-game proof). You may optionally add suggested in-game test checkboxes for the human; never mark them complete. For issue-backed implementation PRs, formally link the owner-supplied GitHub issue in Development and only then check **I've linked this PR to any related issues** — see root `AGENTS.md` (**Issue-backed PR Development linking**). Do not invent unrelated issue links. Do not claim in-game testing was performed when it was not.

## Optional local references
A Blizzard UI source mirror may exist at:
- BlizzardUI/live/
- BlizzardUI/beta/

Treat these as optional reference material (guard against missing paths).
