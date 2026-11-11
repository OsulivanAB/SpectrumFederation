# Validation, packaging, PR mechanics, and completion standards

Load this before declaring any task done. Root `AGENTS.md` is the canonical
change-area-to-validation map; do not maintain a second inventory here.

## 1. Validation modes

- **Authorized implementation / repair / finalization:** run the required
  affected checks from the canonical map before delivery.
- **Owner-requested review / assessment / readiness:** report evidence and
  gaps; execute checks only when that authorization includes execution. Pure
  assessment reads evidence and runs PR-controlled tests/scripts only when
  the request includes execution.

Run focused checks during implementation and required affected checks before
delivery. Reuse prior results only when relevant code, tests, dependencies,
tooling, and environment remain equivalent. Do not rerun identical checks
merely because another instruction file mentions them. Reducing duplicate
local runs is not permission to skip CI; full CI enforcement is unchanged.

Core commands (CI runners have `python3`; adjust locally if only `python`
exists, and note the substitution in your report):

- `python3 .github/scripts/lint_all.py` — addon Lua (luacheck), workflows
  (yamllint), CI scripts (ruff), plus the chat-output baseline guard
- `python3 .github/scripts/validate_packaging.py`
- `python3 .github/scripts/validate_docs.py`

Select applicable focused Python suites from the root map — e.g.
`python -m pytest tests/test_settings_navigation.py` for settings navigation,
`tests/test_tsm_integration.py` for the TSM adapter,
`tests/test_guild_supplies.py` / `tests/test_guild_gossip.py` for those
subsystems, `tests/test_chat_output_guard.py` +
`tests/test_chat_noise_regression.py` for chat-output policy, etc. For
layout/timer/listener/queue/inspect/sync/cache/retry changes, prefer the
existing Lua 5.1-backed suites that assert bounded execution and convergence.

Never weaken tests, validators, CI, branch protection, release guards, or
error visibility to create a green result.

## 2. Behavioral verification standard

For correctness-critical or stateful repairs, exercise production decisions
and meaningful event sequences — not only isolated helpers or source-text
structure. Prefer a regression that fails on the actual broken behavior and
passes after repair when practical; mock external boundaries without bypassing
the transition at risk. Source-text checks prove structural requirements (load
order, forbidden APIs), not runtime guarantees.

Cover, as relevant: bounded execution, convergence, cancellation, idle
behavior, ownership changes, reload, duplicate/out-of-order events, incomplete
data. Do not demand exhaustive permutations or a new simulator for every
small feature.

Report passed, failed, skipped, not-applicable, and unrun checks separately,
each with reason and residual uncertainty. Never claim a code trace was an
executed test, or that mocked tests were live-client QA.

## 3. Readiness standard

Before calling work ready, establish: acceptance criteria; understood
production paths; current-head automated evidence; disposition of actionable
findings; relevant sync/persistence/auth/lifecycle/performance checks; scope
discipline; and required human Retail QA. See review-and-repair.md §7 for
handoff language.

## 4. Packaging and versioning

- `SpectrumFederation/SpectrumFederation.toc` is authoritative for
  version/interface/load order. Every new packaged Lua file goes into its
  owning TOC in dependency order; parent TOCs must not load child-addon
  files. Packaged child Version/Interface values stay aligned.
- Version bumps follow `release_required` in
  `.github/scripts/classify_promotion_scope.py` and
  `.github/scripts/check_version_bump.py`: packaged addon/release-packaging
  changes require an appropriate bump; instruction/docs/infra-only changes do
  not when the branch format is already valid. Beta versions use
  `X.Y.Z-beta.N`; stable releases use `X.Y.Z`.
- A PR already ahead of its base does not automatically need another
  increment per repair. Do not change TOCs or release logic for
  instruction-only changes, and do not bump for this skill package itself.

## 5. PR mechanics

- Use the complete `.github/pull_request_template.md` structure: preserve
  headings, order, prompts, and checklist; report actual validation. Always
  mark **WoW Client Type → Retail** (product target, not in-game proof).
- Never check **I have tested these changes in-game** (human-owned). Check
  **In-game testing is not applicable** only under the current template
  policy (no packaged changes, or allowlisted TOC metadata/proven excluded
  files). Runtime fields, assets, localization, unknown packaged files, and
  load-order changes require human QA. `.github/scripts/validate_pr_template.py`
  enforces the one-in-game-testing-state rule.
- Audit localization before checking its box (SpectrumFederation/AGENTS.md
  → Localization).
- Issue-backed implementation PRs: create the formal Issue ↔ PR Development
  relationship per root `AGENTS.md` (**Issue-backed PR Development
  linking**). `Fixes #N` text or timeline mentions are not proof. Do not
  retarget to `main` to get automatic closing. Check the linked-issue box
  only after the formal link succeeds; otherwise report the manual step.
- Workflow changes: preserve required checks and the exact
  `copilot-setup-steps` job name. Keep Python helpers dependency-light (std
  library, `pathlib`, `subprocess.run`) and keep docs aligned with real
  workflows, `requirements-docs.txt`, and `mkdocs.yml`.

## 6. Honest completion report

End every task with:

- what changed and why (root cause for bugs);
- validations run, with results; skipped/not-applicable with reasons;
- findings disposition summary for review work (reviewed SHA, decisions,
  deferrals awaiting owner acceptance);
- remaining blockers, validation gaps, and required human Retail QA;
- for combined mode: confirmation of stop conditions met.

Do not present a documentation walkthrough or reasoning as an agent test. If
available tooling prevented a check (e.g. missing local Lua/pytest
toolchain), say exactly what could not run and let CI or the owner cover it.
