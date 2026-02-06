---
applyTo: ".github/workflows/**/*.yml,.github/workflows/**/*.yaml"
---

# GitHub Workflows Instructions

- Do **not** modify workflows unless the task explicitly requires it.
- Never weaken or bypass checks to “make CI pass.”
- Keep actions pinned to stable major versions (e.g., `actions/checkout@v5`).
- Validate YAML changes with the repo linter:
  - `python3 .github/scripts/lint_all.py`
- For `copilot-setup-steps.yml` specifically:
  - job name **must** be exactly `copilot-setup-steps`
  - GitHub only honors certain keys for that job (steps/permissions/runs-on/etc). Keep it simple.
