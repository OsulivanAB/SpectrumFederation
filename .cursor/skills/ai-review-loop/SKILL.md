---
name: ai-review-loop
description: >-
  Coordinates SpectrumFederation pull-request review rounds from initial
  handoff through human handoff. Use when implementation is ready for review,
  when review findings arrive, when a review completes with no findings, when
  relevant CI completes or fails, when resuming an existing PR, and at final
  review checkpoints. Owns reviewer sequencing, round state, batching, and
  push timing. Does not replace per-finding replies or the Codex lifecycle
  document.
---

# AI Review Loop

Coordinate automated review as a convergence process. Cursor implements and fixes code. Reviewers identify possible problems; they do not decide what code should change.

This skill owns round coordination, reviewer sequencing, completion handling, finding batches, and push timing. Triage each finding with `.cursor/skills/pr-review-comments/SKILL.md`. Codex review scope, the final integration sweep, and when previous coverage must be reconsidered stay in `.github/codex-review-guidance.md`. Follow that document for those decisions. Do not restate it here.

These files guide the agent that is running now. They do not start a background worker, and they do not guarantee that a later event will be delivered to this session.

## When to start

Start this skill at each of these transitions, including when the pull request has no findings yet:

- initial handoff after implementation is ready for review
- arrival of review findings
- completion of a review that reports no findings
- relevant CI completion or failure
- resuming work on an existing pull request
- final-review checkpoints and human handoff

A clean review is a transition. Read the result and decide the next checkpoint. Do not wait for a finding that will not arrive.

## Continuation

When this run exposes `cursor-subscriptions` tools, read each tool's schema and use the tool that matches the event:

- `cursor-subscriptions-subscribe_github_pr` for later pull-request comments, reviews, and thread updates. It delivers events after the subscription `openTime`. It does not backfill comments that already exist. Fetch the current comments, reviews, threads, and checks immediately when the subscription starts and whenever work resumes.
- `cursor-subscriptions-subscribe_github_ci` for CI completion on the pull request.

These tools are absent on some runs, including a Cloud Agent automation running as a team service account. If a required tool is missing or the subscribe call fails, stop and give this handoff:

```text
This session cannot resume on its own when <event> arrives. Start a new session at that point. The new session must read .cursor/skills/ai-review-loop/SKILL.md, then load the current PR head SHA, merge base, review comments, review status, and checks before it acts.
```

Replace `<event>` with the specific review result or CI result being waited on. Do not invent a polling daemon or a second scheduler. A bounded status read is allowed before concluding that an expected review did not start: read the reviewer summary, check, or reply once. If it is still running, subscribe or hand off. Do not post another request while it is running.

On resume, fetch existing findings and review state before waiting for a future event.

## Start each round

Keep this state in the session notes. On resume, reconstruct it from the current head, review comments, checks, and reviewer summaries. Do not commit a bookkeeping file, and do not post a status comment that mentions a reviewer. A committed status file or an accidental reviewer mention can itself trigger a review.

Record:

- current pull-request head SHA
- merge base, or the base branch SHA used for the diff
- reviews expected for this round
- each expected review's state: requested, running, completed, or blocked
- the commit or commit range each available result covers

Read the current PR requirements, the applicable `AGENTS.md` files, and `.github/codex-review-guidance.md` before editing. Inspect current HEAD. A review comment can describe an older commit.

A reviewer that was not scheduled for the round is not a reviewer to wait for.

### Which reviews belong in the round

| Round | Wait for | Do not request |
| --- | --- | --- |
| Initial handoff | Configured Codex review of this head, including Security Review when the Codex summary lists it, plus one accepted CodeRabbit full review of this head, plus relevant CI | Bugbot; a second Codex request while Codex is already queued, running, or completed for this head |
| Ordinary fix batch | Configured automatic Codex review of the new head, plus relevant CI | CodeRabbit; Bugbot; an immediate manual `@codex review` for the same push |
| Final Codex integration | The one explicit final whole-PR integration review | CodeRabbit and Bugbot until that Codex lifecycle step is complete |
| Final independent checkpoints | One CodeRabbit full review when its allowance is available and this head lacks equivalent completed coverage; Bugbot only for a production-affecting PR | Another Codex full review solely because this checkpoint started |
| Narrow fix after a final checkpoint | Targeted verification of the behavior that fix affects | A new unrestricted whole-PR review from every reviewer |

A pull request is production-affecting when it changes packaged addon or runtime files, or release, packaging, or workflow behavior that can publish or promote a release. Reviewer instructions alone do not make it production-affecting. When it is unclear whether a changed file ships or changes release behavior, treat the pull request as production-affecting.

At the start of the initial round, request the CodeRabbit full review and let the configured Codex review run. Do not wait for one of those reviews to finish before requesting the other. Do not post a separate `@codex security review` when the summary already includes that review for this head.

## What counts as reviewed

A result is clean only when the reviewer finished a review of the code being accepted, and that review reported no actionable findings still open against current HEAD.

These are not a clean review:

- no comments yet
- a review still running
- a skipped review
- a rate-limited review
- a failed or canceled review
- a generic green status with no evidence that the review occurred
- a clean result for an older head, unless the applicable incremental-review rules in `.github/codex-review-guidance.md` still cover the later commits

Before advancing a checkpoint, verify that the required coverage applies to the current code. Preserve an earlier review when that Codex document allows an incremental review. Do not require every reviewer to repeat a full review after a narrow fix.

This repository disables CodeRabbit automatic review in `.coderabbit.yaml` (`reviews.auto_review.enabled: false`). A CodeRabbit comment that says auto-review was skipped is the idle state. It is not a completed review and it is not an exhausted allowance. The checkpoint still requires an accepted manual request.

Codex completion evidence is the summary comment from `chatgpt-codex-connector`: its status, commit, and trigger, plus a 👀 reaction while a review is running and a 👍 reaction when the finished reviews have no findings. A 👍 counts only for the commit named in that summary. Bugbot completion evidence is a finished `Cursor Bugbot` check, or Bugbot's own review comment, for that head. `success` means Bugbot found no issues and left no unresolved earlier Bugbot comments. `neutral` and `failure` are not clean: `neutral` can mean findings, cancellation by a newer commit, or an internal error.

## Run the round

1. Collect review comments and relevant CI results for the current head.
2. Investigate findings that are already available while other expected reviews are still running. Use `.cursor/skills/pr-review-comments/SKILL.md` for each finding. Do not push yet.
3. Before finalizing the batch, confirm that every review expected for this round has completed or has a documented unavailable outcome.
4. Fetch findings again so results that arrived during investigation are included.
5. Validate and deduplicate the complete set against current HEAD.
6. Fix legitimate issues, run the applicable validation, and push once if the batch changes code.

If another push lands during the round, refresh the head SHA and merge base, then reassess findings and coverage. Do not implement a stale finding against the new code. An in-flight clean result for the previous head does not cover the new head.

No code change is required when every finding is already fixed, duplicated, or unsupported. Do not create a commit or push only to give a reviewer something new to look at.

### Classify every finding

Classify each finding as one of:

- **valid/open** — the defect is reachable and remains present in current HEAD
- **already fixed** — current HEAD no longer contains the reported problem
- **duplicate** — another finding describes the same root cause
- **incorrect/missing context** — the finding does not hold after tracing the actual code and lifecycle
- **follow-up/out of scope** — potentially useful work, but not a defect caused by this PR and not required by the ticket

Do not modify production code merely because a reviewer suggested a change. For a valid finding, establish the triggering path and root cause before choosing a fix.

### Batch the round

After classification:

1. Consolidate findings that share a root cause.
2. Design the smallest coherent fix for all valid/open findings.
3. Check affected callers, consumers, shared state, persistence, synchronization, and lifecycle behavior.
4. Implement the complete batch.
5. Add or update tests when they can meaningfully protect the behavior.
6. Run the applicable repository validation.
7. Re-inspect the resulting diff for review-induced complexity.
8. Push once for the entire review round.

Use this sequence:

```text
collect -> validate -> deduplicate -> fix batch -> test -> one push
```

A push can trigger another paid or limited review. Replying to one thread does not push and does not start another review. Thread replies and resolution stay in `.cursor/skills/pr-review-comments/SKILL.md`.

## Request a checkpoint

Post a checkpoint as a new top-level pull-request comment with `ManagePullRequest` `post_comment`, omitting `in_reply_to`. Do not use `gh` to write comments. Do not post the request as a reply on a review thread. Do not treat a comment authored by another bot as a request those reviewers will accept.

If `ManagePullRequest` is unavailable, the checkpoint is blocked. Report the exact comment a person must post from an account the reviewer accepts. Do not claim the review was requested.

After posting, verify that the reviewer accepted the request and that a review then finished. The comment's presence is not acceptance, and acceptance is not a completed review.

### CodeRabbit

Command reference: `@coderabbitai full review` reviews the whole pull request, and `@coderabbitai review` reviews incrementally since the last CodeRabbit review.

- Initial checkpoint: post `@coderabbitai full review` once for the initial completed pull-request state.
- Final checkpoint: post `@coderabbitai full review` once for the final checkpoint state when the allowance is available.
- Targeted follow-up: post `@coderabbitai review` when an incremental recheck of a narrow fix is appropriate.
- Do not request CodeRabbit after every ordinary Codex fix push.

Skip a full-review request when this head already has an equivalent completed CodeRabbit full review, or when that full review is already requested or running for this head. Wait for the in-flight review instead of posting another. If it is unclear whether the existing result is a full review of this head, it is not equivalent coverage. Do not request another CodeRabbit review merely to consume remaining quota. If the only result for this unchanged head is a rate limit, record that unavailable outcome once. Do not post the final full-review request as an immediate retry.

After the manual request, a rate-limited, failed, canceled, or other non-review result is an unavailable checkpoint. Say that. Do not label it clean, do not waive a known valid finding, and do not enable a paid continuation. The configured auto-review skip, before any manual request, is not this outcome.

### Codex

During ordinary iterations, let the configured automatic review run after a substantive fix push. Check the Codex summary for a queued or running review before requesting anything. Do not immediately add `@codex review` for that same round.

If the expected automatic review does not start, read the summary status, commit, and trigger, and check for a 👀 reaction. When nothing is queued or running for the current head, one plain `@codex review` comment is allowed. If that comment is accepted, do not post it again. If it is not accepted, mark Codex blocked and tell a human to check the Codex GitHub connection.

When `.github/codex-review-guidance.md` requires the final integration review, and that review is not already queued or running, post this once:

```text
@codex review

Perform the final whole-PR integration sweep required by .github/codex-review-guidance.md. Review the entire pull request against its merge base. This is the final integration review, not an incremental fix review.
```

Do not create an empty commit to trigger that review. If Codex does not accept the request, mark the final sweep blocked and report that a human must confirm it. Do not post a second copy.

### Bugbot

Do not invoke Bugbot during ordinary Codex iterations.

At the final checkpoint for a production-affecting pull request, post one top-level comment containing exactly `cursor review` or exactly `bugbot run`. Post only one of them. If a Bugbot run is already queued, or the `Cursor Bugbot` check is in progress for this head, do not post the other.

Verify that Bugbot accepts the request and that the check or review finishes for this head. The comment itself is not a completed review. A `Cursor Bugbot` result for an older head does not cover later commits.

After a Bugbot finding is fixed, prefer the installation's configured review of new commits. Request another manual Bugbot run only when that incremental behavior will not cover the fix and the fix still needs Bugbot verification. Do not restart an entire review cycle automatically. Do not enable or imitate Bugbot Autofix. Cursor remains the code-writing agent.

### Blocked checkpoints

If a required checkpoint cannot run because of permissions, an unavailable tool, a service failure, or an exhausted paid allowance, mark it blocked. Name the reviewer, the head SHA, the evidence, and the exact next human action. Do not treat the checkpoint as passed.

## Codex lifecycle

Use the transitions below only to choose which part of `.github/codex-review-guidance.md` applies. That document remains the definition of Codex completion.

- **Initial whole-PR review.** The first Codex review of the pull request. If it is clean for the current head, Case A applies: do not request another full Codex review only to satisfy this process.
- **Incremental fix review.** After a fix batch, review the new commits as that document describes for subsequent reviews. A clean incremental result does not replace the final integration sweep in Case B.
- **Final whole-PR integration review.** After an incremental review is clean, request the one final sweep above. Advance to the CodeRabbit and Bugbot final checkpoints only after the applicable Codex case is complete.
- **Targeted verification.** When the final integration review finds an issue, fix it and follow Case C: incremental review of that fix, including the targeted integration sweep it requires. A narrow fix does not restart an unrestricted whole-PR review. A broad change that makes earlier coverage unreliable follows that document's full-review fallback rules.

## WoW-specific validation

For changes to shipped addon behavior, explicitly inspect relevant risks from the applicable repository instructions, including:

- Lua 5.1 compatibility
- UI-thread stalls or freezes
- callbacks, events, timers, tickers, and `OnUpdate`
- feedback loops and re-entrancy
- queues and retry convergence
- cleanup and duplicate registration
- long-session resource growth
- asynchronous item, inspection, and game data
- SavedVariables and profile compatibility
- synchronization authorization, identity, deduplication, ordering, and amplification
- addon-message storms
- protected UI, combat restrictions, and taint
- optional integration boundaries
- TOC, version, and release correctness

Do not claim that in-game testing occurred unless a human performed it. Do not weaken tests, CI, review requirements, or error visibility to make a pull request look clean. Do not spend a round on speculative or style-only churn.

## Convergence safety valve

A real defect remains actionable regardless of how many rounds have occurred.

Count a non-clean fix round only when a coordinated batch is pushed because at least one finding was valid and open. Individual comments and findings do not increment the count. Resuming the session does not reset it. A different reviewer reporting the next issue does not reset it. A round that pushes nothing does not increment it.

Keep the count in the session notes. On resume, reconstruct it from the pull request's review-fix commits and prior discussion. If earlier fix rounds are visible, do not start the count at zero.

After five consecutive non-clean fix rounds, pause autonomous rewriting. Summarize:

- unresolved defects
- reviewer disagreements
- areas repeatedly rewritten
- tests currently covering the behavior
- suspected requirement or architectural ambiguity

Ask a human for direction. The pause is not permission to merge or to ignore a defect.

## Completion

Automated review is ready for human handoff only when:

- applicable CI checks are green, or an unavailable check is explicitly identified
- the applicable Codex lifecycle in `.github/codex-review-guidance.md` is complete for the current head
- reported Security Review findings are resolved or explicitly dispositioned
- the final CodeRabbit checkpoint completed for this head, or its unavailable outcome is recorded without calling it clean
- Bugbot completed for this head on a production-affecting pull request, or that required checkpoint is recorded as blocked
- no known valid review finding remains unresolved
- human-only WoW Retail verification is clearly identified when the change requires it

Do not merge on the user's behalf unless explicitly instructed and authorized.
