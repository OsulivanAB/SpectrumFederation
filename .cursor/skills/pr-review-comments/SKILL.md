---
name: pr-review-comments
description: >-
  Investigates one SpectrumFederation pull-request review finding with
  evidence-based classification and recommendation. Use when a finding arrives
  through an intentionally active review subscription, or when an
  owner-authorized assessment or repair batch includes the finding. Posts a
  disposition reply when subscription triage or an explicit owner request
  authorizes that write. Never edits code, commits, pushes, starts a repair
  batch, or requests another review.
---

# PR Review Comments

Use this skill to triage one finding. That includes human reviews, Codex,
CodeRabbit, Bugbot, and other inline discussion threads.

Authorization for batches, validation, escalation, checkpoint recommendations,
and push timing belong to `.cursor/skills/ai-review-loop/SKILL.md`. Codex
review scope and coverage belong to `.github/codex-review-guidance.md`.

## When this skill may run

A finding may be triaged when either:

1. **Subscribed review event:** the finding was delivered through an
   intentionally active / owner-authorized review subscription; or
2. **Owner-authorized operation:** the owner authorized an assessment or repair
   batch that includes the finding.

A subscribed finding does **not** require a fresh owner request before triage
and disposition reply. Unsolicited general events that are not subscribed
review findings still do not start this skill.

This skill must **not** independently:

- edit code;
- modify tests to implement a repair;
- commit or push;
- resolve a thread without explicit resolution authorization;
- request another review or another reviewer;
- start a repair batch;
- create new subscriptions, poll, wait, or schedule follow-up;
- investigate unrelated findings outside the delivered or owner-named set.

Recommendation and authorization are separate. An IMPLEMENT recommendation is
advice to the owner; it is never permission to implement.

## Scope and current state

Refresh PR/branch state when needed. Read the cited code at current HEAD and
load only the thread, surrounding code, tests, contracts, PR description,
linked ticket/issue when available, repository instructions, documentation,
and accepted product/architecture decisions needed to decide it. Do not judge
a review comment in isolation from what the feature is supposed to accomplish.
If the branch changed, refresh and reassess. A finding may target an older
commit. Do not inspect every historical thread by default.

## Workflow

Follow this order for each finding.

1. **Establish evidence:** identify the triggering condition, reachable failure
   path, impact, and violated requirement or invariant at current HEAD, and
   whether the finding still applies. Reproduction or a regression test is
   preferred when practical during a repair batch; during subscription triage,
   prefer a well-supported code and lifecycle trace without prototyping a
   repair. Do not dismiss a credible defect solely for lacking automated
   reproduction.
2. **Classify:** confirmed/open, already fixed, duplicate, unsupported, needs
   more evidence, or product/architecture decision. Do not make speculative
   changes for a repeated but refuted finding.
3. **Recommend:** form an explicit engineering recommendation —
   **IMPLEMENT**, **DO NOT IMPLEMENT**, or **OWNER DECISION / MORE EVIDENCE
   REQUIRED**. This is advice, not authorization to carry out the
   recommendation.
4. **Return / reply with the disposition:**
   - For **subscription-event triage**, posting one reply to that finding’s
     thread is authorized after steps 1–3. Reply, then stop.
   - For an **owner-authorized assessment** that did not authorize replies,
     return the classification and recommendation without posting unless the
     request also authorized the write.
   - For an **owner-authorized repair batch**, reply after the batch’s single
     delivery when replies were authorized so the response can name the fixing
     commit.
5. **Resolve only when authorized:** resolve a confirmed finding when it is
   fixed in current HEAD, including an `already fixed` finding whose original
   defect was confirmed and whose fix remains in current HEAD, **and**
   resolution was explicitly authorized. Leave unsupported, disputed,
   decision-dependent, or unresolved findings open for human consideration.
   Subscription triage alone does **not** authorize resolution, including for
   already-fixed, duplicate, unsupported, or do-not-implement outcomes.

### Investigation depth during subscription triage

Be technically meaningful without turning triage into an implementation cycle.

Allowed **non-executing inspection** only: read current code; inspect relevant
callers and sibling paths; inspect tests/docs/task context as source text;
inspect recent relevant history when needed; reason through state/lifecycle
behavior from that evidence.

Do not automatically: modify production code or tests; prototype a repair;
redesign the subsystem; perform a broad unrelated audit; run repository tests
or other PR-controlled scripts/diagnostics (including helpers that
`import`/`loadfile`/`exec` checked-out code); commission another AI reviewer;
or request another review. Running PR-controlled tests or scripts during
automatic subscription triage requires a separate owner authorization or an
immutable isolated sandbox provided by external infrastructure.

If validity needs substantial experimentation, Retail testing, a redesign, or
expensive investigation, classify as “needs more evidence” or
“product/architecture decision”, explain what is missing, recommend the
smallest next step, reply, and stop.

## Thread reply format

The reply should help both the owner and the reviewer without becoming a large
report. It should normally contain:

- classification;
- recommendation;
- concise evidence/reasoning;
- relevant current-HEAD behavior or requirement;
- any important uncertainty or decision needed.

Intended substance (wording may be shorter and natural):

```text
Confirmed/open — IMPLEMENT.

This path can remove the archive row that predates the rejected batch because
eviction occurs before rollback and the evicted row is not restored. That
violates the transaction invariant that rejecting the batch leaves
pre-existing accounting state unchanged.

I recommend repairing this in the next owner-authorized batch. No code changes
were made as part of this assessment.
```

```text
Unsupported — DO NOT IMPLEMENT.

Current HEAD already bounds this retry through <specific mechanism>, and the
cited path cannot re-enter once <condition> is cleared. The suggested
additional state would duplicate the existing lifecycle control.

I do not recommend implementing this finding. No code changes were made.
```

```text
Product/architecture decision — OWNER DECISION REQUIRED.

Both behaviors are technically viable, but the review assumes retention policy
X while the current task/docs imply Y. Changing this would alter the product
contract rather than correct an established defect.
```

## Reply and resolve

- Reply with `ManagePullRequest` `post_comment` and `in_reply_to` set to the
  review comment id. Do not use `gh` to write comments.
- Resolve with `ManagePullRequest` `resolve_comment` only after the reply, only
  when step 5 applies, and only when resolution was authorized.
- Do not resolve a thread just because you replied, and do not resolve merely
  because subscription triage classified the finding.
- If `ManagePullRequest` is unavailable, do not switch to another writer.
  Report that the reply was not posted and leave the thread unresolved.

## Multiple findings in one delivered review

When one subscribed review completion delivers several findings, triage each
delivered finding and reply on its corresponding thread. Consolidate
duplicate/root-cause-equivalent findings where appropriate without hiding
distinct defects. Do not treat the delivery as authorization for a broad new
PR audit. After the delivered findings are assessed and replied to, stop.

## Constraints

- When a comment or requested review covers runtime addon behavior, treat
  client stability as a top dimension even if the prompt does not mention
  crashes. Report only credible freeze/hang/runaway mechanisms after tracing
  callers, lifecycle, bounds, and termination. See
  `SpectrumFederation/AGENTS.md` Client Stability.
- When review touches user-visible messages, especially on recurring paths
  (heartbeats, timers, sync, retries), check for repetition/spam risk per
  `SpectrumFederation/AGENTS.md` (User-visible messaging → Anti-spam and
  repetition). Treat uncontrolled identical repeats as an implementation-
  quality issue.
- Do not reopen settled product or architecture decisions unless current
  repository evidence makes them impossible.
- Do not weaken CI, skip validation, or mark in-game testing complete in the
  PR template. In-game QA is human-owned. You may mark in-game testing N/A only
  when there are no packaged addon/runtime changes except allowlisted TOC
  metadata or proven non-shipped files (see `.cursor/rules/pr-template.mdc`).
- Keep replies factual and specific to the cited code.
- Preserve quality standards: verify against current HEAD; establish credible
  reachability; inspect relevant invariants and sibling paths; distinguish
  original defects from repair-induced regressions when readily knowable;
  avoid speculative hardening and unrelated cleanup; preserve
  persistence/synchronization/accounting correctness; treat credible client
  freezes/runaway execution as correctness defects; distinguish automated
  verification from required Retail QA; avoid dismissing real defects merely
  because they are late, expensive, rare, or inconvenient.
- A confirmed defect remains a defect even though implementation waits for
  human authorization.
