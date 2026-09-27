---
name: pr-review-comments
description: >-
  Investigates one GitHub pull request finding, replies on its thread, and
  decides whether that thread may be resolved. Use for an individual human,
  Codex, CodeRabbit, or Bugbot comment. Does not commit, push, or start
  another review; batch implementation and push timing belong to
  ai-review-loop.
---

# PR Review Comments

Use this skill to triage one review finding on the current pull request. That includes human reviews, Codex, CodeRabbit, Bugbot, and other inline discussion threads.

Round coordination, reviewer sequencing, completion handling, batch implementation, validation, and push timing belong to `.cursor/skills/ai-review-loop/SKILL.md`. Codex review scope, the final integration sweep, and when previous coverage must be reconsidered belong to `.github/codex-review-guidance.md`.

If a review event arrives and a review round is not already in progress, start `ai-review-loop` first. Triage the finding here, then return the classification to that round. Following this process for every comment means every comment is read, classified, and answered. It does not mean every comment gets its own commit or push.

## Subscriptions do not backfill

GitHub PR subscriptions (`cursor-subscriptions-subscribe_github_pr`) deliver future events only. Comments, reviews, and review threads that already exist when the subscription's `openTime` is recorded are not delivered.

When a PR subscription starts, or when work resumes on an existing PR, immediately list unresolved review threads and issue comments. Triage them inside the current `ai-review-loop` round. Do not wait for a later subscription delivery, and do not push after each thread.

## Workflow

Follow this order for each finding. Reply on the thread. Do not GitHub-resolve a thread just because you replied. Do not commit, push, or request a review from this skill.

1. **Read** the comment and the cited code at the current branch HEAD, not only the commit the review targeted. Fetch the thread, surrounding code, related tests, and any approved design or contract that bounds the change.
2. **Determine** whether the comment is correct and necessary, or whether the reviewer missed context:
   - **Valid and still open:** the cited behavior is wrong, incomplete, or unsafe in current HEAD. Record it for the current `ai-review-loop` batch.
   - **Valid but already fixed:** HEAD already addresses it. Do not invent extra work.
   - **Incorrect or missing context:** the reviewer did not see the approved contract, a later commit, or a deliberate boundary. Do not change the code to satisfy a misunderstanding.
3. **Return that classification to the review round.** `ai-review-loop` decides whether any valid findings become one tested batch and one push. A reply on this thread does not push the branch and does not request another review.
4. **Always reply** on the review thread. Say whether the comment was accepted, already fixed, or declined, and point to the commit or the reason. Reply as soon as the disposition is known. When the fix is part of the current batch, send that reply after the round's one push so it names the commit that contains the fix. A declined, duplicate, or already-fixed finding is answered without waiting for a push.
5. **Resolve the GitHub thread only when** the comment was valid **and** the issue is actually resolved in HEAD (by the round's commit or by a prior commit). Leave the thread open when the comment was declined, disputed, misunderstood context, or still needs follow-up. Declined and disputed findings stay available for human consideration.

## Reply and resolve

- Reply with `ManagePullRequest` `post_comment` and `in_reply_to` set to the review comment id. Do not use `gh` to write comments.
- Resolve with `ManagePullRequest` `resolve_comment` only after the reply, and only when step 5 applies.
- Do not resolve a thread just because you replied.
- Do not leave a valid, fixed comment unanswered.
- If `ManagePullRequest` is unavailable, do not switch to another writer. Report that the reply was not posted and leave the thread unresolved.

## Constraints

- When a comment or requested review covers runtime addon behavior, treat client stability as a top dimension even if the prompt does not mention crashes. Report only credible freeze/hang/runaway mechanisms after tracing callers, lifecycle, bounds, and termination. See `SpectrumFederation/AGENTS.md` Client Stability.
- When review touches user-visible messages, especially on recurring paths (heartbeats, timers, sync, retries), check for repetition/spam risk per `SpectrumFederation/AGENTS.md` (User-visible messaging → Anti-spam and repetition). Treat uncontrolled identical repeats as an implementation-quality issue.
- Do not reopen settled product or architecture decisions unless current repository evidence makes them impossible.
- Do not weaken CI, skip validation, or mark in-game testing complete in the PR template. In-game QA is human-owned. You may mark in-game testing N/A only when there are no packaged addon/runtime changes except allowlisted TOC metadata or proven non-shipped files (see `.cursor/rules/pr-template.mdc`).
- Keep replies factual and specific to the cited code.
