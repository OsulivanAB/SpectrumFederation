# SpectrumFederation – Copilot Instructions

These instructions guide GitHub Copilot coding agent and VS Code Agent Mode for this repo.

## Non‑negotiables
- **Version bump is mandatory:** Any PR that changes addon behavior, code, UI, settings, packaging, or SavedVariables **MUST** bump `## Version:` in `SpectrumFederation/SpectrumFederation.toc`.
  - **beta branch:** increment `-beta.N` (e.g., `0.4.0-beta.7` → `0.4.0-beta.8`)
  - **main branch:** bump SemVer (patch/minor/major as appropriate)
- **Do not bypass CI:** never change workflows/checks to “make it green.”
- **WoW Lua only:** Lua 5.1 sandbox (no `io`, `os`, Lua 5.2+ features).

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
- Prefer reusing existing settings controls and renderers; don’t introduce a second settings framework.

## Validation (always do before finalizing)
Run the unified linter:
```sh
python3 .github/scripts/lint_all.py
```

## Optional local references
A Blizzard UI source mirror may exist at:
- BlizzardUI/live/
- BlizzardUI/beta/

Treat these as optional reference material (guard against missing paths).

