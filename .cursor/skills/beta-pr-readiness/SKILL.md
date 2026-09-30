---
name: beta-pr-readiness
description: Prepares SpectrumFederation changes for merge by selecting the right validations and checking beta-first release constraints. Use when finishing addon, docs, workflow, packaging, or version-related work.
---

# Beta PR Readiness

Use this skill when a task is close to done and you need a repo-specific merge-readiness pass.

## Checklist

1. Classify the changed files:
   - packaged addon runtime or TOC (`release_required`)
   - docs or `README.md`
   - workflows, CI scripts, or instruction/configuration files
   - interface sync tests/fixtures
2. Read the relevant guidance:
   - `AGENTS.md` for repo-level orientation, validation modes, and the
     **canonical Validation By Change Area map**
   - `SpectrumFederation/AGENTS.md` for addon work
   - matching `.cursor/rules/*.mdc`
3. Select validations from the canonical map in root `AGENTS.md`. Do not
   maintain a second full map here. Domain skills may still name their focused
   suite. Run checks under authorized implementation/finalization mode; for a
   readiness-only request, execute only when that authorization includes
   running them.
4. If the change touches addon packaging, release logic, or TOC-driven
   behavior, inspect `SpectrumFederation/SpectrumFederation.toc` before
   finishing. Version bumps follow deterministic `release_required`
   classification: packaged addon/release-packaging changes require a bump;
   instruction/docs/infra-only changes do not when the TOC format is already
   valid for the target branch. A repair iteration does not automatically
   require another increment when the PR version is already valid for delivery.
5. If the change involves UI layout, sizing, callbacks, events, timers,
   listeners, queues, inspection, synchronization, caches, or retries, confirm
   the existing Lua 5.1 suite for that area covers bounded execution,
   convergence, and relevant behavioral sequences where practical. Do not invent
   counters everywhere; follow `SpectrumFederation/AGENTS.md` Client Stability.
6. When filling the PR template, follow `.cursor/rules/pr-template.mdc`: never
   check **I have tested these changes in-game**; check **In-game testing is not
   applicable** only when there are no packaged addon/runtime changes except
   allowlisted TOC metadata or proven non-shipped files; always check **WoW
   Client Type → Retail**; never check linked issues unless the user provided
   the link. Do not claim in-game testing was performed when it was not.
7. For workflow changes, verify checks were not weakened and
   `copilot-setup-steps` still uses the required job name.
8. For docs changes, compare commands and workflow names against the actual
   files in `.github/workflows/` and `.github/scripts/`.

## Output

Report:

- validations run
- validations still recommended but not run
- release/version concerns, if any
- remaining blockers or residual risk
- when code work is done and only human Retail QA remains: state
  "Implementation and automated validation complete; awaiting human Retail QA"
  without treating that gate as a code defect or weakening the human checkbox
