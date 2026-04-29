# SpectrumFederation – Copilot Instructions

These instructions guide GitHub Copilot coding agent and VS Code Agent Mode for this repo.

## Non‑negotiables
- **Version bump is mandatory — do this FIRST, every time:**
  - Any PR that changes addon behavior, code, UI, settings, packaging, or SavedVariables **MUST** bump `## Version:` in `SpectrumFederation/SpectrumFederation.toc` **before finalizing**.
  - **Every PR on the beta branch** (including documentation or `.github/` only changes) must ensure the TOC version has a valid `-beta.N` suffix. If it does not, fix it as part of your PR.
  - **beta branch:** the version **MUST** always end in `-beta.N`. Increment N by 1 (e.g., `0.4.0-beta.7` → `0.4.0-beta.8`). A plain SemVer like `0.4.0` is **never** valid on the beta branch.
  - **main branch:** bump SemVer (patch/minor/major as appropriate); drop the `-beta.N` suffix.
  - **Check the TOC file early** — read `SpectrumFederation/SpectrumFederation.toc` at the start of every task, note the current version, and include the bumped version in your first commit.
  - Forgetting the version bump is a blocker; do not submit a PR without it.
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

## Pull request descriptions
- **Always use the repository PR template** at `.github/pull_request_template.md` when creating or updating a PR description.
- Preserve the template's section headings, order, checklist items, and prompts; do not replace the template with a custom format.
- Copy the template structure into the PR body and fill it in; do **not** submit only a summary, only a checklist, or any alternate layout.
- Do **not** wrap the PR title or PR description in custom XML/HTML tags such as `<pr_title>` or `<pr_description>`.
- If any tool temporarily overwrites the PR description while reporting progress, restore the full repository PR template before finishing the task.
- Fill out every section **to the best of your ability** using the information available from the task, code changes, validation, and testing performed.
- If a section does not apply or you do not have the information, keep the template section and state that clearly instead of omitting it.
- When a tool asks for a PR title/description, first read the template and then format the response to match it.

## Optional local references
A Blizzard UI source mirror may exist at:
- BlizzardUI/live/
- BlizzardUI/beta/

Treat these as optional reference material (guard against missing paths).
