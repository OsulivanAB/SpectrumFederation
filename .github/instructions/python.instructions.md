---
applyTo: ".github/scripts/**/*.py"
---

# Python (CI Scripts) Instructions

- Target Python 3 (GitHub Actions runner).
- Keep scripts dependency-light; prefer the standard library.
- Use `pathlib` and `subprocess.run` patterns already present in this repo.
- Ensure changes remain compatible with `ruff check` (run `python3 .github/scripts/lint_all.py`).
