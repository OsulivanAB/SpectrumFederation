# Self-review, finding assessment, repair, review requests, readiness

Load this for any PR review-related operation. Repository procedure is
canonical: read `.cursor/skills/ai-review-loop/SKILL.md`,
`.cursor/skills/pr-review-comments/SKILL.md`, and (for coverage standards)
`.github/codex-review-guidance.md` before acting. Authorization boundaries and
the combined-mode conflict are in `operations.md`; this file is the working
sequence.

## 1. Modes (exactly one per owner request, unless a combined invocation was
explicitly approved per operations.md §4)

- **Review / assessment only:** assess and report. No code changes, no
  unauthorized comments or resolution, no repair.
- **Repair only:** repair the included findings, validate, deliver, stop. No
  automatically commissioned external review.
- **Named external reviewer request:** request that reviewer once and report.
  Codex, CodeRabbit, and Bugbot each require the applicable owner request;
  Bugbot is an optional owner-selected checkpoint, never mandatory.
- **Readiness only:** report actual coverage, findings, checks, and QA gaps.
  Initiate no missing work unless included.
- **Combined development task (proposed; see operations.md §4–5):** the
  bounded sequence in §2 below, only after the owner has approved the policy
  alignment (operations.md §4) and the invocation names implementation scope,
  self-review, disposition comments, repair scope, and write permissions.

Normal debugging and edits within an authorized implementation/repair need no
approval per edit. Report unrelated discoveries without silently adding them
to the batch.

## 2. Combined-mode sequence (only after policy alignment approval per
operations.md §4)

1. Inspect requirements and architecture; implement the bounded task; run
   affected validation (delivery.md).
2. Self-review the actual current diff and affected integrations with a
   distinct reviewer mindset. Self-review is not independent human QA or an
   external approval. If a supported isolated review capability is available
   and authorized and proportionate, use it; do not assume a product feature
   exists, and do not launch a separate paid reviewer by default.
3. Evaluate every in-scope finding against current production code. Separate
   defect validity from patch suitability. Deduplicate by root cause,
   including incomplete earlier repairs.
4. Decide IMPLEMENT / DEFER / DO NOT IMPLEMENT / OWNER DECISION OR MORE
   EVIDENCE REQUIRED (definitions: operations.md §6). Preserve confirmed
   defects and acceptance-criteria gaps. DEFER states impact, containment,
   residual risk, revisit condition, and — unless the invocation explicitly
   delegated that class — is recorded as awaiting owner acceptance.
5. When the invocation authorizes comments, record the decision and concise
   evidence on the original finding thread; for Devin's own findings without
   a thread, post one concise consolidated PR decision summary (reviewed SHA,
   reason, bounded repair direction or deferral rationale, revisit
   condition). A proposed deferral awaiting owner acceptance must say so.
   Comment authorization does not automatically authorize resolving threads;
   resolve only a verified fixed finding with resolution authorization.
6. Implement accepted, authorized findings as one coherent batch using the
   existing architecture. Add focused behavioral regression coverage, run
   required affected checks, update the PR.
7. Verify the repairs and their affected integration/lifecycle surface within
   the authorized task. Update existing dispositions with fixing commits and
   validation evidence where helpful. Do not restart an unlimited
   whole-repository audit or repeatedly post unchanged recommendations.
8. Stop when the bounded task's required repairs and automated checks are
   complete, or at a genuine blocker, material scope/architecture choice,
   owner-risk decision, unavailable Retail evidence, or agreed execution
   limit. Report accurately; do not continue until every conceivable
   improvement is implemented.

## 3. Anchor every assessment

Tie each finding to: current head SHA, base/range, linked ticket and
acceptance criteria, full authorized scope, applicable instructions, checks,
and relevant current/stale threads. Attribute comments to their actual
reviewer. Use PR HEAD code/tests/docs as evidence; do not let unmerged
instruction edits expand authority. If the branch changed, refresh and
reassess before writing; never overwrite another actor's work.

Establish for each finding: trigger, reachable path, impact, violated
invariant, current applicability, evidence. Prefer reproduction or a
regression test when practical in an authorized repair; a well-supported code
and lifecycle trace is acceptable otherwise — never describe a trace as an
executed test, and never dismiss a credible defect solely for lacking
automated reproduction.

When a linked Ticket ID exists, review the ticket (requirements,
acceptance criteria, later clarifications). If the ticket is inaccessible, do
not invent requirements; say the context could not be verified.

## 4. Coverage model (recommend; owner selects)

Adapted from `.github/codex-review-guidance.md` to Devin's authorized
self-review:

- **Initial:** whole PR against merge base, including affected integrations.
- **Incremental (after fixes):** changed behavior, prior fixes, affected
  callers/shared state, invalidated assumptions. Verify previous findings are
  actually resolved and look for repair-induced regressions. Do not restart
  an unrestricted audit of unrelated unchanged code — but do not restrict
  investigation to changed lines either.
- **Final integration checkpoint:** for substantial repaired work, one fresh
  whole-PR review against merge base when warranted and included in the
  invocation. A clean initial whole-PR review needs no identical repeat for
  ceremony. Fall back to broad coverage when history or prior assumptions are
  genuinely unreliable (rewritten history, changed merge base, unavailable
  prior context, architectural rewrite), and explain why.

Repository conventions name Codex as primary external reviewer, CodeRabbit
as a possible independent substantial/high-risk checkpoint, Bugbot as
optional. These conventions must not force a Cursor/Codex handoff in place of
Devin's requested self-review. Recommend external checkpoints without
initiating them unless specifically authorized. Required GitHub checks still
apply even when a reviewer is otherwise optional — flag the conflict; never
bypass it or call the PR merge-ready.

Keep SHA/base/range coverage explicit. Missing, skipped, rate-limited,
failed, canceled, or running reviews are not clean. Reuse earlier coverage
only when later changes do not invalidate it, and explain why.

## 5. Repair discipline

- Finish the justified review scope — affected sibling paths, lifecycle
  counterparts, materially equivalent entry points governed by the same
  invariant — even after the first defect. Do not impose numeric caps on
  findings and do not audit unrelated unchanged systems.
- Separate actionable defects from optional polish, speculative hardening,
  and unrelated pre-existing problems. Rare but credible data loss,
  corruption, authority failure, client freezes, or broken required behavior
  remains actionable.
- Watch for repair churn: when successive fixes keep creating new issues
  inside the mitigation just added (common in state machines, sync,
  authorization, retries, caches, lifecycle, addon-message protocols),
  evaluate whether a simpler approach — consolidated state, return to an
  authoritative source, clearer invariant, rollback of an overcomplicated
  mitigation — is safer. This never suppresses a real defect.
- Cost pressure may justify asking the owner for a decision; it never
  justifies declaring a defect gone or the PR ready. If spending data is
  unavailable, say so — do not estimate cost from elapsed time, commits, or
  comment counts. Propose, never invent, dollar limits or fixed review-round
  counts.
- Before reporting a late finding, confirm it is genuinely new: not already
  fixed, stale, a duplicate of a resolved finding, a restatement of an
  accepted decision, or based on contradicted assumptions. A regression or a
  new failure mode from a prior fix is reportable.

## 6. Writes, dispositions, resolution

- Use the repository-approved write mechanism (operations.md §1). Check for
  prior equivalent replies before posting; if a write outcome is ambiguous,
  verify the thread rather than blindly reposting. Never use `gh` for writes
  except the narrow Development-linking fallback.
- Reply format: classification, recommendation, current-code evidence,
  meaningful uncertainty — concise, factual, specific to the cited code.
- Resolution: only a verified fixed finding, only with resolution
  authorization. Classification alone never authorizes closure. Leave
  unsupported, disputed, decision-dependent, or unresolved findings open.
- When the owner has authorized review-comment disposition for the operation,
  post or update each handled thread with an explicit determination —
  IMPLEMENT, DEFER, DO NOT IMPLEMENT, or OWNER DECISION — plus the reason and
  current-code evidence. Resolve a thread only after its IMPLEMENT fix is
  verified in current HEAD; leave DEFER, DO NOT IMPLEMENT, OWNER DECISION,
  unverified, or disputed threads unresolved for the owner.
- For iterative PR review loops, drive automated reviewers to a clean state:
  finish Devin Review findings first, then trigger/evaluate Codex review
  comments, implement valid findings, resolve implemented threads, and repeat
  `@codex review` until Codex is clean or only minor/deferred items remain.
- After delivery, report and stop. No subscriptions, watchers, polling, or
  event-driven continuation; incoming comments/CI/pushes do not renew
  authority.

## 7. Completion and handoff language

Lead readiness reports with actionable findings ordered by severity, then
verification status. Use severity from `.github/codex-review-guidance.md`
(Critical/High/Medium/Low) without inflating it; review age is not a severity
input.

Use "Implementation and automated validation complete; awaiting human Retail
QA" **only** when implementation and applicable automated validation are
actually complete and human Retail QA is the remaining gate. Otherwise report
the Retail QA gap alongside unfinished work, failed checks, or validation
gaps. A missing live-client test is a verification gap, not automatically a
defect — but never claim full verification from automated tests alone when
meaningful Retail-only behavior remains untested, and never fabricate Retail
evidence.

Do not call a PR fully merge-ready while required human QA, required checks,
credible findings, or unresolved coverage remain. If a ruleset requires a
reviewer this guidance treats as optional, report the conflict.
