---
name: pr-review-comments
description: Handles GitHub pull request review comments, including Bugbot. Use when a PR review arrives, when asked to address review feedback, or when deciding whether to reply, implement, or resolve a review thread.
---

# PR Review Comments

Use this skill for review comments on the current pull request (human reviews, Bugbot, and inline discussion threads).

## Workflow

Follow this order on every comment. Do not skip the reply, and do not GitHub-resolve a thread just because you replied.

1. **Read** the comment and the cited code at the current branch HEAD, not only the commit the review targeted. Fetch the thread, surrounding code, related tests, and any approved design or contract that bounds the change.
2. **Determine** whether the comment is correct and necessary, or whether the reviewer missed context:
   - **Valid and still open:** the cited behavior is wrong, incomplete, or unsafe in current HEAD. Implement a fix.
   - **Valid but already fixed:** HEAD already addresses it. Do not invent extra work.
   - **Incorrect or missing context:** the reviewer did not see the approved contract, a later commit, or a deliberate boundary. Do not change the code to satisfy a misunderstanding.
3. **If it is relevant and still open in HEAD**, implement the fix, add or update tests when that area already has them, and commit. Push the branch and update the PR when this repo's process requires it.
4. **Always reply** on the review thread. Say whether the comment was accepted, already fixed, or declined, and point to the commit or the reason.
5. **Resolve the GitHub thread only when** the comment was valid **and** the issue is actually resolved in HEAD (by a new commit or by a prior commit). Leave the thread open when the comment was declined, misunderstood context, or still needs follow-up.

## Reply and resolve

- Reply with `ManagePullRequest` `post_comment` and `in_reply_to` set to the review comment id. Do not use `gh` to write comments.
- Resolve with `ManagePullRequest` `resolve_comment` only after the reply, and only when step 5 applies.
- Do not resolve a thread just because you replied.
- Do not leave a valid, fixed comment unanswered.

## Constraints

- Do not reopen settled product or architecture decisions unless current repository evidence makes them impossible.
- Do not weaken CI, skip validation, or mark in-game testing complete in the PR template. In-game QA is human-owned. You may mark in-game testing N/A only when there are no packaged addon/runtime changes except allowlisted TOC metadata or proven non-shipped files (see `.cursor/rules/pr-template.mdc`).
- Keep replies factual and specific to the cited code.
