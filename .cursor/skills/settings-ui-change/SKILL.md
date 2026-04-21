---
name: settings-ui-change
description: Modifies SpectrumFederation settings or settings UI using the repo's schema-store-apply-render workflow. Use when adding toggles, pages, controls, defaults, or settings-driven behavior.
---

# Settings UI Change

Use this skill for work in `SpectrumFederation/modules/Settings/` or `SpectrumFederation/modules/UI/Settings/`.

## Workflow

1. Read `SpectrumFederation/AGENTS.md` and the matching docs under `docs/development/settings-ui/`.
2. For a new or changed setting, follow the repo flow in order:
   - define or update the setting in `modules/Settings/Schema.lua`
   - confirm storage behavior in `modules/Settings/Store.lua`
   - wire runtime behavior in the feature module or `modules/Settings/Apply.lua`
   - render it through the existing settings UI under `modules/UI/Settings/`
3. Reuse the existing page builder, registry, definition renderer, and control helpers instead of introducing a parallel settings framework.
4. If the change adds user-facing text, check whether `locale/enUS.lua` should own the string.
5. If the change adds a new packaged Lua file, update `SpectrumFederation/SpectrumFederation.toc` in load order.

## Validation

- Run `python3 .github/scripts/lint_all.py`
- Recommend in-game verification with `/reload` and a quick settings UI smoke test
