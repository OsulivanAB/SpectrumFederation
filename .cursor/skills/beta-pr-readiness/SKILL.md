---
name: beta-pr-readiness
description: Prepares SpectrumFederation changes for merge by selecting the right validations and checking beta-first release constraints. Use when finishing addon, docs, workflow, packaging, or version-related work.
---

# Beta PR Readiness

Use this skill when a task is close to done and you need a repo-specific merge-readiness pass.

## Checklist

1. Classify the changed files:
   - addon runtime or TOC
   - docs or `README.md`
   - workflows or CI scripts
   - interface sync tests/fixtures
2. Read the relevant guidance:
   - `AGENTS.md` for repo-level orientation
   - `SpectrumFederation/AGENTS.md` for addon work
   - matching `.cursor/rules/*.mdc`
3. Run the smallest validation set that matches the touched areas:
   - `python3 .github/scripts/lint_all.py`
   - `python3 .github/scripts/validate_packaging.py`
   - `python3 .github/scripts/validate_docs.py`
   - `python -m pytest tests/test_wow_interface_sync.py`
   - `python -m pytest tests/test_interface_badge.py` when README badges or `blizzard_api.py` display conversion changed
   - `python -m pytest tests/test_settings_navigation.py` when Settings navigation/Registry/TOC metadata changed
   - `python -m pytest tests/test_mouse_tracer.py` when Mouse Tracer constants, engine, or runtime tests changed
   - `python -m pytest tests/test_loot_helper_window.py` when Loot Helper window minimize or positioning changed
   - `python -m pytest tests/test_sync_protocol.py` when SyncProtocol NACK/warning throttling changed
   - `python -m pytest tests/test_settings_window_layout.py` when Settings window content layout or the impersonation banner changed
   - `python -m pytest tests/test_linked_identity.py` when linked identities changed
   - `python -m pytest tests/test_bis_reconstruction.py` when item-aware BiS reconstruction changed
   - `python -m pytest tests/test_pr_template.py` when the PR template or `validate_pr_template.py` changed
   - `python -m pytest tests/test_promotion_scope.py` when promotion workflows or `classify_promotion_scope.py` changed
   - `python -m pytest tests/test_check_version_bump.py` when version-bump comparison or `check_version_bump.py` changed
4. If the change touches addon packaging, release logic, or TOC-driven behavior, inspect `SpectrumFederation/SpectrumFederation.toc` before finishing.
5. If the change involves UI layout, sizing, callbacks, events, timers, listeners, queues, inspection, or synchronization, confirm the existing Lua 5.1 suite for that area covers bounded execution and convergence where practical. Do not invent counters everywhere; follow `SpectrumFederation/AGENTS.md` Client Stability.
6. When filling the PR template, follow `.cursor/rules/pr-template.mdc`: never check **I have tested these changes in-game**; check **In-game testing is not applicable** only when there are no packaged addon/runtime changes except allowlisted TOC metadata or proven non-shipped files; always check **WoW Client Type → Retail**; never check linked issues unless the user provided the link. Do not claim in-game testing was performed when it was not.
7. For workflow changes, verify checks were not weakened and `copilot-setup-steps` still uses the required job name.
8. For docs changes, compare commands and workflow names against the actual files in `.github/workflows/` and `.github/scripts/`.

## Output

Report:

- validations run
- validations still recommended but not run
- release/version concerns, if any
- remaining blockers or residual risk
