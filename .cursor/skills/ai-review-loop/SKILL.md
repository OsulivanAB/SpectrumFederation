---
name: ai-review-loop
description: >-
  Runs one owner-authorized SpectrumFederation pull-request assessment, repair
  batch, review request, or readiness evaluation. Use only when a person
  clearly requests that operation; events and prior blanket instructions do
  not authorize continuation.
disable-model-invocation: true
---

# Human-Directed Review Batches

This is the canonical procedure for review-related work. Despite the stable
`ai-review-loop` path, it is not an autonomous loop. A clear natural-language
owner request such as “address the current review comments in one batch” is
sufficient; the owner does not need to invoke a slash command.

Review comments, CI or review completion, clean reviews, thread resolution,
pushes, session restarts, scheduled events, and old “keep going” instructions
never start, expand, or renew authorization. Do not subscribe to review or CI
events, poll or wait for them, schedule continuation, or automatically request
another reviewer. After the authorized operation is delivered, report and stop.

Triage individual findings with
`.cursor/skills/pr-review-comments/SKILL.md`. Review scope and coverage rules
stay in `.github/codex-review-guidance.md`. Preserve repository tool
permissions: use `ManagePullRequest` for authorized GitHub writes, never use
`gh` for writes, and never merge unless separately and explicitly authorized.

## Choose exactly one authorized operation

- **Assess/triage:** inspect current findings and report classifications. Do not
  change code, resolve threads, or request a review.
- **Repair one batch:** investigate and fix the findings named or clearly
  included by the request and their directly affected behavior; validate,
  deliver once, and stop. Straightforward edits and debugging inside that batch
  need no redundant approval.
- **Request a review:** initiate only the explicitly named reviewer or
  checkpoint, once, through an authorized available tool. This operation does
  not authorize later repairs, waiting, or another request.
- **Evaluate readiness:** report coverage, unresolved findings, CI state,
  required manual QA, and conflicts with required checks. Do not initiate
  missing checks, modify code, resolve threads, request reviews, or merge.

Explicit limits in the current owner request take precedence. If the request is
only an assessment, observation of a credible bug is not repair authorization.
If an external event arrives without a new owner request, report it only when
asked; do not start this procedure.

## Start an authorized operation

Refresh the branch and identify, in a few sentences:

- pull request and current head SHA, plus merge base or base SHA when relevant;
- completed reviews and exact commit or range each result covers;
- findings and affected production behavior included in the authorization;
- a proportionate validation plan.

On resume, refresh HEAD and load only relevant new findings and reliable prior
context. Do not repeatedly load every historical discussion. If another actor
changed the branch, reassess before writing and never overwrite their work.
Missing, skipped, rate-limited, failed, canceled, or running reviews are not
clean results.

For future large cross-subsystem features, make a short initial assessment of
source-of-truth ownership, durable state, lifecycle risks, and verification,
then propose coherent implementation milestones before building a large
dependency chain. Skip that ceremony for small local fixes. Bring forward
targeted Retail checks before later work depends on uncertain trade, bank,
combat, or WoW API behavior.

## Investigate findings by root cause

For every candidate finding, establish current-HEAD evidence of the triggering
condition, reachable failure path, practical impact, and violated requirement
or invariant. Prefer reproduction or a regression test when practical. A
well-supported code trace is acceptable when the real environment cannot be
reproduced; do not dismiss a credible defect solely for lacking automated
reproduction.

Classify each finding as:

- **confirmed/open**
- **already fixed**
- **duplicate**
- **unsupported**
- **needs more evidence**
- **product/architecture decision**

Consolidate symptoms with one root cause without concealing distinct defects.
Where readily established from recent commits or tests, distinguish an
original defect from a regression introduced by a prior fix. Otherwise mark
attribution unknown; do not perform an expensive historical audit solely to
assign blame.

For each confirmed defect:

1. Briefly state the behavior that must remain true.
2. Inspect sibling entry points, callers, shared state, and lifecycle
   transitions governed by that rule within the affected scope.
3. Choose the smallest coherent repair, not necessarily the fewest changed
   lines.
4. Test the production behavior and relevant boundaries rather than
   duplicating implementation logic in tests.
5. Run affected validation and inspect the resulting diff.

Newly discovered defects in the same approved root-cause and impact surface may
be repaired in the batch. Report unrelated discoveries without silently
expanding scope. If a dependency makes the repair unsafe or substantially
larger, stop for a scope decision.

## Implement and deliver one repair batch

Normal local engineering autonomy remains intact: inspect affected
dependencies, run tests, debug failures caused by the batch, and revise the fix
until supportable. A batch may contain several edits and test runs, but it does
not permit indefinite architectural expansion.

Use this sequence:

```text
refresh -> investigate -> classify -> consolidate -> repair -> validate -> inspect -> deliver once -> stop
```

When delivery is authorized, make at most one push for the batch. Do not push
per finding. Do not create an artificial commit when nothing changed. Thread
replies and resolutions remain governed by
`.cursor/skills/pr-review-comments/SKILL.md` and require authorization for
external writes. Do not wait for or act on reviews or CI triggered by the push.

Keep routine handoffs short: scope/head, meaningful fixes, validation evidence,
unresolved decisions or manual QA, and a recommended next action. Do not commit
round bookkeeping or generate elaborate reports by default.

## Pause for a decision

Pause the affected work when:

- repairs repeatedly break the same invariant or would reverse an accepted fix;
- reviewers disagree about required behavior, retention, compatibility, or
  authority;
- repair changes a product contract, requires a substantial new state machine,
  or expands across unrelated subsystems;
- reliable resolution needs Retail evidence unavailable in the environment.

Report the conflict, evidence, remaining risk, and a bounded recommended next
step. Do not automatically redesign, split the PR, revert work, or commission
an unrestricted audit. A directly understood local correction or an ordinary
test failure does not require escalation.

Real data loss, incorrect accounting, authorization failures, crashes/freezes,
serious regressions, and broken required behavior remain blockers. Do not
suppress credible P2 findings or demote a defect because it is old, rare,
expensive, or inconvenient. There is no numeric cap on legitimate findings
within an authorized review. Low-impact limitations need explicit owner
acceptance before deferral. A budget pause leaves a defect open; it does not
make the PR ready. Optional polish, speculative hardening, and unrelated
cleanup are not mandatory repair scope.

## Human-selected review checkpoints

Recommend checkpoints; never schedule them automatically:

- **Codex:** primary code reviewer. Initial review covers the whole PR and
  affected integrations. Ordinary rechecks focus on fixes and their impact,
  including relevant unchanged callers and shared state.
- **CodeRabbit:** independent checkpoint for substantial or high-risk changes.
  It is not required after every ordinary fix. Recommend an early checkpoint
  only when it can validate a consequential design before later work depends
  on it.
- **Bugbot:** optional independent check when requested or justified by a
  distinct risk; never mandatory merely because an older process used three
  reviewers.

For substantial changes after the initial review, retain the final whole-PR
integration checkpoint in `.github/codex-review-guidance.md`. A clean initial
whole-PR review does not need an identical repeat for ceremony. After a
final-checkpoint finding, recommend targeted coverage unless the repair
materially invalidates previous coverage.

All review requests require a current owner authorization naming the reviewer
or checkpoint. If recommending a broad review, identify the uncovered gap or
invalidated assumption. Remaining quota is not a reason to request a review.
Instructions about incremental scope do not guarantee provider token use or
execution details.

Keep SHA, base, and range coverage explicit. Reuse earlier coverage only when
later changes do not invalidate it, and explain why. A required GitHub check
still applies even when this guidance calls that reviewer optional: flag the
policy conflict and do not bypass it or call the PR merge-ready.

An authorized review request is one external write. Request it once through an
available authorized tool, report whether the request was made, and stop. Do
not wait for acceptance or completion.

## WoW-specific validation

For shipped addon behavior, inspect applicable Lua 5.1, persistence,
synchronization, authorization, optional-integration, client-stability,
bounded-execution, and lifecycle risks in the repository instructions. Use
targeted tests that exercise production behavior and convergence. Preserve
human-owned Retail QA and never fabricate in-game evidence.

Do not weaken tests, CI, branch protection, required checks, review quality, or
error visibility to make a PR look clean.

## External owner settings — not changed by this procedure

These are owner actions outside repository instruction edits:

- stop or pause active feature agents separately;
- disable or pause Cursor automations that start repairs or reviews from PR,
  comment, review, CI, or scheduled events; retain deterministic CI;
- set Codex automatic and Security Review triggers to the owner’s manual-review
  policy while retaining desired manual review capability;
- set Bugbot to manual triggering and Autofix off, including personal and
  installation overrides;
- keep unrequested paid continuation and agent fixing disabled in CodeRabbit
  account settings;
- set an owner-chosen service-level spending limit;
- inspect required-review rules before treating optional reviewers as
  skippable;
- after merge, bring these instruction changes into active feature branches
  and explicitly restart or resume agents under the new policy.

Instruction text cannot enforce a per-PR dollar budget. Report actual spend
only from a trustworthy usage source; otherwise say it is unavailable and do
not estimate it from time, commits, or findings.
