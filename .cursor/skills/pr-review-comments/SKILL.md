---
name: pr-review-comments
description: >-
  Investigates one explicitly authorized GitHub pull-request finding and
  returns an evidence-based classification. Replies or thread resolution are
  separate external writes and occur only when authorized. This skill never
  starts a repair batch or another review.
---

# PR Review Comments

Use this skill to triage one finding when the owner authorized an assessment or
repair batch that includes it. That includes human reviews, Codex, CodeRabbit,
Bugbot, and other inline discussion threads.

Authorization, batch implementation, validation, escalation, checkpoint
recommendations, and push timing belong to
`.cursor/skills/ai-review-loop/SKILL.md`. Codex review scope and coverage
belong to `.github/codex-review-guidance.md`.

The arrival of a review event does not authorize triage, repair, a reply,
thread resolution, or another review. Do not start
`ai-review-loop`, subscribe to later events, poll, wait, or schedule follow-up.
Wait for a current owner request.

## Scope and current state

Read the cited code at current HEAD and load only the thread, surrounding code,
tests, and contracts needed to decide it. If the branch changed, refresh and
reassess. A finding may target an older commit. Do not inspect every historical
thread by default.

## Workflow

Follow this order for each finding. Do not commit, push, request a review,
reply, or resolve a thread from this skill unless the current owner request
explicitly authorizes the corresponding external write.

1. **Establish evidence:** identify the triggering condition, reachable failure
   path, impact, and violated requirement or invariant at current HEAD.
   Reproduction or a regression test is preferred when practical; a
   well-supported trace is acceptable when the real environment cannot be
   reproduced.
2. **Classify:** confirmed/open, already fixed, duplicate, unsupported, needs
   more evidence, or product/architecture decision. Do not make speculative
   changes for a repeated but refuted finding.
3. **Return the classification:** the authorized operation decides whether a
   confirmed finding enters one root-cause-based repair batch. This skill does
   not independently expand scope.
4. **If replies were authorized:** reply factually after the disposition is
   known. For a batch fix, reply after its single delivery so the response can
   name the fixing commit.
5. **If thread resolution was authorized:** resolve only when a confirmed
   finding is actually fixed in current HEAD. Leave unsupported, disputed,
   decision-dependent, or unresolved findings open for human consideration.

## Reply and resolve

- Reply with `ManagePullRequest` `post_comment` and `in_reply_to` set to the
  review comment id. Do not use `gh` to write comments.
- Resolve with `ManagePullRequest` `resolve_comment` only after the reply, only
  when step 5 applies, and only when resolution was authorized.
- Do not resolve a thread just because you replied.
- If `ManagePullRequest` is unavailable, do not switch to another writer. Report that the reply was not posted and leave the thread unresolved.

## Constraints

- When a comment or requested review covers runtime addon behavior, treat client stability as a top dimension even if the prompt does not mention crashes. Report only credible freeze/hang/runaway mechanisms after tracing callers, lifecycle, bounds, and termination. See `SpectrumFederation/AGENTS.md` Client Stability.
- When review touches user-visible messages, especially on recurring paths (heartbeats, timers, sync, retries), check for repetition/spam risk per `SpectrumFederation/AGENTS.md` (User-visible messaging → Anti-spam and repetition). Treat uncontrolled identical repeats as an implementation-quality issue.
- Do not reopen settled product or architecture decisions unless current repository evidence makes them impossible.
- Do not weaken CI, skip validation, or mark in-game testing complete in the PR template. In-game QA is human-owned. You may mark in-game testing N/A only when there are no packaged addon/runtime changes except allowlisted TOC metadata or proven non-shipped files (see `.cursor/rules/pr-template.mdc`).
- Keep replies factual and specific to the cited code.
