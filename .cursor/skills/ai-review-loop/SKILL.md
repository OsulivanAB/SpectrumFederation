---
name: ai-review-loop
description: Triage and resolve automated pull-request review findings in batches. Use when a SpectrumFederation PR has Codex, CodeRabbit, Bugbot, GitHub review, or CI findings that must be validated, fixed, tested, and pushed without creating wasteful one-comment-per-push review loops.
---

# AI Review Loop

Handle automated review as a convergence process, not as a sequence of blindly
accepted comments.

Cursor is the implementation/fix agent. Reviewer bots identify possible
problems; they do not automatically determine what code should be changed.

## Start each round

Before editing:

1. Read the current PR/ticket requirements.
2. Read the applicable `AGENTS.md` files.
3. Read the current repository review guidance.
4. Inspect current HEAD rather than assuming a review comment still describes
   the code.
5. Collect all currently available findings from Codex, CodeRabbit, Bugbot,
   GitHub review comments, and relevant CI failures.

Do not begin pushing fixes after reading only the first comment.

## Classify every finding

Classify each finding as one of:

- **valid/open** — the defect is reachable and remains present in current HEAD;
- **already fixed** — current HEAD no longer contains the reported problem;
- **duplicate** — another finding describes the same root cause;
- **incorrect/missing context** — the finding does not hold after tracing the
  actual code and lifecycle;
- **follow-up/out of scope** — potentially useful work, but not a defect caused
  by this PR and not required by the ticket.

Do not modify production code merely because a reviewer suggested a change.

For a valid finding, establish the triggering path and root cause before
choosing a fix.

## Batch the round

After all current findings have been classified:

1. Consolidate findings that share a root cause.
2. Design the smallest coherent fix for all valid/open findings.
3. Check affected callers, consumers, shared state, persistence,
   synchronization, and lifecycle behavior.
4. Implement the complete batch.
5. Add or update tests when they can meaningfully protect the behavior.
6. Run the applicable repository validation.
7. Re-inspect the resulting diff for review-induced complexity.
8. Push **once** for the entire review round.

Do not use this pattern:

```text
finding A -> fix -> push
finding B -> fix -> push
finding C -> fix -> push
```

Use:

```text
collect -> validate -> deduplicate -> fix batch -> test -> one push
```

This matters because a push can trigger another paid or limited review.

## WoW-specific validation

For changes to shipped addon behavior, explicitly inspect relevant risks from
the applicable repository instructions, including:

- Lua 5.1 compatibility;
- UI-thread stalls or freezes;
- callbacks, events, timers, tickers, and `OnUpdate`;
- feedback loops and re-entrancy;
- queues and retry convergence;
- cleanup and duplicate registration;
- long-session resource growth;
- asynchronous item/inspection/game data;
- SavedVariables and profile compatibility;
- synchronization authorization, identity, deduplication, ordering, and
  amplification;
- addon-message storms;
- protected UI, combat restrictions, and taint;
- optional integration boundaries;
- TOC/version/release correctness.

Do not claim that in-game testing occurred unless there is evidence that a human
performed it.

## Reviewer sequencing

Treat Codex as the primary iterative reviewer when repository/user settings
configure it to review every push.

Do not manually invoke Bugbot during ordinary Codex fix iterations.

Do not manually invoke CodeRabbit after every ordinary fix push.

The intended lifecycle is:

```text
implementation
-> initial Codex review
-> initial CodeRabbit checkpoint
-> batched fix round
-> one push
-> Codex review
-> batched fix round
-> one push
-> Codex review
-> ...
-> Codex clean
-> final CodeRabbit checkpoint
-> final Bugbot checkpoint
-> any legitimate final fixes
-> Codex verifies resulting push
-> human review / Retail QA
```

If the current PR or repository is intentionally using a different reviewer
sequence, follow the explicit PR instructions instead.

## CodeRabbit findings

When CodeRabbit is used, distinguish a completed review from a skipped,
rate-limited, or otherwise non-review result.

Do not interpret the absence of findings as a clean review unless CodeRabbit
actually completed the review.

Do not invoke additional CodeRabbit reviews merely to consume available quota.

## Bugbot findings

Bugbot is the independent final backstop for production-affecting PRs.

When Bugbot finds a valid issue:

1. collect all findings from that Bugbot run;
2. validate them;
3. fix legitimate findings as one batch;
4. run applicable tests;
5. push once;
6. allow the primary review loop to inspect the resulting state;
7. request another Bugbot review only when verification of Bugbot-related
   changes is useful.

Do not enable or imitate Bugbot Autofix. Cursor remains the code-writing agent.

## Review comments

For each review thread:

- reply with the result of the investigation;
- state when the issue was fixed and summarize the fix;
- state when it was already fixed;
- state concisely when the finding is incorrect and why;
- do not falsely claim verification that was not performed.

Resolve a thread only when repository workflow permits it and the underlying
valid issue is actually resolved.

## Convergence safety valve

A real defect remains actionable regardless of how many rounds have occurred.

However, after five consecutive non-clean AI fix rounds on the same PR, stop
blind autonomous churn and produce a concise escalation summary containing:

- recurring or newly discovered root causes;
- reviewer disagreements;
- areas repeatedly rewritten;
- tests currently covering the behavior;
- unresolved valid findings;
- suspected requirement or architectural ambiguity.

Do not merge merely because five rounds occurred.

The purpose of the checkpoint is to prevent review-induced complexity and
identify when human judgment is cheaper and safer than another automatic
rewrite.

## Completion

Automated review is ready for human handoff only when:

- applicable CI/checks are green;
- the latest Codex review lifecycle is clean;
- reported Security Review findings are resolved or explicitly dispositioned;
- the final CodeRabbit checkpoint completed when it was intended and available;
- Bugbot completed for production-affecting PRs where required;
- no known valid review finding remains unresolved;
- human-only WoW Retail verification is clearly identified.

Do not merge on the user's behalf unless explicitly instructed and authorized.