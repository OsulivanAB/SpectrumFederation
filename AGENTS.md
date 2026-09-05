# SpectrumFederation Agent Guide

SpectrumFederation is a single-product repository for a World of Warcraft addon, its release automation, and its MkDocs documentation.

## What Lives Where

- `SpectrumFederation/`: packaged parent addon runtime code, TOC manifest, locale files, and bundled libraries.
- `SpectrumFederation_CursedSurgeTracker/`: optional child addon shipped in the same release zip.
- `SpectrumFederation_RCLootCouncilIntegration/`: optional child addon that records RC Loot Council awards in Spectrum Loot Logs, shipped in the same release zip.
- `.github/scripts/`: Python automation for linting, packaging, docs validation, release/version checks, and Blizzard interface sync.
- `.github/workflows/`: GitHub Actions workflows for PR validation, beta releases, promotion to `main`, rollback, and Copilot setup.
- `docs/` + `mkdocs.yml`: documentation source for the published docs site.
- `tests/`: Python tests plus Lua 5.1 tests that load production Settings, Mouse Tracer, and Loot Helper window Lua.
- `SpectrumFederation/AGENTS.md`: deeper addon-specific implementation guidance for work inside the addon tree.

## Source Of Truth

- Treat `SpectrumFederation/SpectrumFederation.toc` as the authoritative addon manifest for load order, interface version, and addon version. Child-addon TOC files must stay on the same Interface and Version values.
- Prefer `.github/workflows/` and `.github/scripts/` over prose docs when they disagree; some docs still mention older workflow names.
- Prefer existing repo scripts over inventing new validation commands.

## Key Commands

- Lint addon, workflows, and CI scripts: `python3 .github/scripts/lint_all.py`
- Validate addon packaging: `python3 .github/scripts/validate_packaging.py`
- Validate docs build: `python3 .github/scripts/validate_docs.py`
- Run targeted parser tests: `python -m pytest tests/test_wow_interface_sync.py`
- Run Interface badge formatting tests: `python -m pytest tests/test_interface_badge.py`
- Run Settings navigation tests (production Lua via lua5.1): `python -m pytest tests/test_settings_navigation.py`
- Run Mouse Tracer engine tests (production Lua via lua5.1): `python -m pytest tests/test_mouse_tracer.py`
- Run Loot Helper window tests (production Lua via lua5.1): `python -m pytest tests/test_loot_helper_window.py`
- Run RC Loot Council Integration tests (production Lua via lua5.1): `python -m pytest tests/test_rc_loot_council_integration.py`
- Run Settings window layout tests (production Lua via lua5.1): `python -m pytest tests/test_settings_window_layout.py`
- Run impersonation tests (production Lua via lua5.1): `python -m pytest tests/test_impersonation.py`
- Run Raid Equipment policy and check-run tests (production Lua via lua5.1): `python -m pytest tests/test_raid_equipment.py`
- Run PR template validator tests: `python -m pytest tests/test_pr_template.py`

## Important Workflows

- Beta-first delivery model: normal feature work flows into `beta`; `main` is promotion-only.
- PR validation lives in `.github/workflows/pr-beta-validation.yml` and `.github/workflows/pr-main-validation.yml`.
- Promotion and rollback live in `.github/workflows/promote-beta-to-main.yml` and `.github/workflows/rollback-release.yml`.
- `copilot-setup-steps.yml` is special: keep the job name exactly `copilot-setup-steps`.

## Where To Start

- Addon feature or bugfix: start in `SpectrumFederation/AGENTS.md`, then inspect the relevant module under `SpectrumFederation/modules/`.
- Settings work: start with `SpectrumFederation/modules/Settings/` and `SpectrumFederation/modules/UI/Settings/`, then read `docs/development/settings-ui/`.
- Mouse Tracer work: start with `SpectrumFederation/modules/MouseTracer/` and `docs/development/mouse-tracer.md`.
- Loot Helper or sync work: inspect `SpectrumFederation/modules/LootHelper/`, `SpectrumFederation/modules/LootHelperSync/`, and the related docs under `docs/development/loot-helper/`.
- Workflow or CI script work: inspect the matching file under `.github/workflows/` or `.github/scripts/` first, then use `.github/instructions/` as supplemental guidance.
- Docs work: start with `mkdocs.yml` for nav/build behavior, then edit files in `docs/`.
- PR descriptions: follow `.cursor/rules/pr-template.mdc`. Never check **I have tested these changes in-game**. You may check **In-game testing is not applicable** only when there are no packaged addon/runtime changes, except allowlisted TOC metadata or files proven not to ship. Always check **WoW Client Type → Retail**. Leave linked issues to the human unless they provided the link.
- PR review comments: follow `.cursor/skills/pr-review-comments/SKILL.md`.

## Validation By Change Area

- Addon Lua, TOC, workflows, or CI scripts: run `python3 .github/scripts/lint_all.py`
- Packaging or release behavior: also run `python3 .github/scripts/validate_packaging.py`
- Docs, `README.md`, or `mkdocs.yml`: also run `python3 .github/scripts/validate_docs.py`
- `wow_interface_sync.py` or parser fixtures/tests: also run `python -m pytest tests/test_wow_interface_sync.py`
- README Interface badge formatting or `blizzard_api.py` display conversion: also run `python -m pytest tests/test_interface_badge.py`
- Settings navigation or Registry helpers: also run `python -m pytest tests/test_settings_navigation.py`
- Mouse Tracer constants or trail engine: also run `python -m pytest tests/test_mouse_tracer.py`
- Loot Helper window minimize/positioning: also run `python -m pytest tests/test_loot_helper_window.py`
- RC Loot Council Integration child addon: also run `python -m pytest tests/test_rc_loot_council_integration.py`
- Settings window impersonation-banner layout: also run `python -m pytest tests/test_settings_window_layout.py`
- Loot Helper impersonation / Preview as Non-Admin: also run `python -m pytest tests/test_impersonation.py`
- Raid Equipment policy, CheckRun, or Raid Check lifecycle: also run `python -m pytest tests/test_raid_equipment.py`
- PR template or `validate_pr_template.py`: also run `python -m pytest tests/test_pr_template.py`
- Release classification or Wago publishing: also run `python -m pytest tests/test_publish_release.py`
