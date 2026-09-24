# Codex Pull Request Review Guidance

This document defines the expected behavior for Codex pull request reviews in this repository.

The goal is to determine whether a pull request is safe to become the new production state of the repository. Reviews should converge. They should not become an open-ended cycle of full review, fix, and another unrestricted full review.

Convergence does not lower the quality bar. A real defect stays actionable when it is found late, when a previous review fix introduced it, when the PR has already been reviewed several times, or when fixing it is inconvenient. Repeated rounds should not keep expanding the PR into adjacent hardening, unrelated edge cases, or increasingly elaborate machinery unless the finding is a credible defect in the production state this PR would create.

Prioritize correctness, regressions, integration risk, runtime behavior, persistence, synchronization, performance, security, release safety, and meaningful verification over cosmetic preferences.

---

## Review Principles

Act as a senior engineer protecting production quality, not as a style checker.

- Inspect before assuming.
- Verify important claims against the repository rather than trusting the PR description, implementation summary, comments, or passing tests.
- Trace important behavior to its source of truth.
- Review impact across subsystem boundaries when a change can affect callers, consumers, persisted data, synchronization, settings, UI, tests, packaging, release behavior, or documentation.
- Prefer well-supported findings over a long list of weak possibilities. Finish the current review scope before submitting feedback. Discovering the first actionable defect is not a reason to stop. See [Exhaust the Current Review Scope](#exhaust-the-current-review-scope).
- If there are no meaningful findings, say so. Do not manufacture issues to produce review output.
- Do not ignore a real defect because the review is late or because an earlier fix caused it.
- Do not treat every theoretical improvement as mandatory scope for the PR under review.

---

## Exhaust the Current Review Scope

Within the scope of the current review, discovering an actionable defect is not a stopping condition. Finish examining that scope before submitting feedback. Report the distinct, high-confidence actionable defects found there, so related problems can be fixed together.

Do not maximize comment count. There is no numeric minimum or maximum for findings. Every finding must still be high-confidence, actionable, and inside the current review scope. Do not manufacture speculative issues to fill the review. A later review may still find a bug that a previous fix introduced. Exhausting the current scope is how already-existing defects in that scope get reported together. It is not a promise that new code can never contain a new bug.

### When an invariant is broken

If a defect shows that an underlying invariant or policy is broken, inspect the other paths in the current review scope that the same invariant governs before finishing. Where the change actually reaches them, that includes:

- authorization and trust decisions
- coordinator or owner transitions
- state-machine transitions
- synchronization
- persistence
- request routing
- retry behavior
- cache creation and invalidation
- lifecycle handling
- restore and reload
- cleanup
- privilege changes
- UI-thread or performance-sensitive processing

If an authorization bug appears in one way of becoming coordinator, consider the sibling coordinator entry points in scope where the same authorization rule is expected to hold.

### Lifecycle counterparts

For newly changed machinery, consider the parts of its lifecycle that the change actually affects: creation, mutation, use, invalidation, reset, restore, timeout, cleanup, and failure handling. This matters most for state machines, caches, sync state, retry bookkeeping, authorization state, persistence, and addon-message protocols.

### Sibling entry points

If several entry points perform materially equivalent operations, and those siblings are inside the current review's impact surface, a defect in one is a reason to inspect the others in the same review. Do not leave an obvious sibling inside that surface for a later review request.

### Related tests

When a defect is found, inspect the relevant tests for other variants of the same rule. Consider whether the tests demonstrate the invariant across the materially affected paths, not only the exact case that triggered the finding. A missing variant belongs with that finding. It is not, by itself, a second defect.

### One cause, one finding

If several symptoms are one underlying defect, prefer one well-supported root-cause finding that names the affected paths. Use separate findings when the defects have different causes, need materially different fixes, or have independently important consequences. Do not collapse unrelated defects into one comment to reduce the count, and do not split one cause into several comments to increase it.

### Stay inside the scope

Exhaust the current review scope, then stop at its boundary.

An incremental review's scope is the new commits since the last reliably reviewed state, whether prior findings were actually fixed, regressions those fixes introduced, the callers and consumers they affect, relevant shared state, the lifecycle and state transitions they directly affect, and integration assumptions the change invalidates. It does not automatically include unrelated unchanged portions of the PR.

A full review's scope is the entire PR against its merge base: the changed subsystems and the integration paths those changes can reach. Finding an actionable defect is not a reason to stop before the remaining changed subsystems and affected integration paths have been examined. It is not a reason to audit unrelated unchanged code outside that impact. Reporting several findings does not, by itself, schedule another whole-PR review.

---

## Review Lifecycle

Use a staged review process so fixes receive focused review while the completed PR still receives a full integration sweep.

### Initial Review

On the first review of a PR:

- Review the **entire PR against its merge base**.
- Evaluate the implementation as a whole, including relevant production code, tests, configuration, workflows, persistence, documentation, and integration points.
- Review the related ticket when one is provided.
- Establish the initial set of actionable findings.

The initial review stays broad. Include the related ticket, production behavior, integration points, persistence, synchronization, performance, security and trust boundaries, tests, packaging and release behavior, and other subsystem effects the change can reach.

Do not limit the initial review to the newest commit or the files emphasized by the PR description.

A full review continues across the changed subsystems and the integration paths they can reach even after an actionable defect has already been found. Finish that scope before submitting the review. See [Exhaust the Current Review Scope](#exhaust-the-current-review-scope).

If the initial full review has no actionable findings, no additional full review is required solely for process reasons. Complete the applicable automated verification and document any remaining Retail QA.

### Subsequent Reviews

After fixes or other new commits are pushed, review incrementally and by impact:

- Identify the last commit that was reliably reviewed.
- Review the commits added since that point.
- Verify that previous findings were actually resolved.
- Look for regressions introduced by those fixes.
- Follow changed behavior through the callers, consumers, shared state, persistence, communications, and state transitions the fix directly affects.
- Check assumptions the new change invalidates.
- Do **not** routinely restart an unrestricted audit of unrelated, unchanged portions of the PR.
- Do not restrict investigation to changed lines. Inspect unchanged code when that is what it takes to understand the consequences.

When reviewing a fix, exhaust the affected invariant and integration surface before submitting feedback. If the change fixes one entry point, inspect sibling entry points governed by the same rule when they are inside this incremental scope. See [Exhaust the Current Review Scope](#exhaust-the-current-review-scope). Reporting several findings from that pass does not turn the incremental review into an unrestricted audit, and it does not by itself schedule another whole-PR review.

If actionable issues are found during the incremental reviews that follow the initial review, report the distinct high-confidence defects in that scope, then repeat incremental review after they are fixed. Do not start the final integration review until one of those incremental reviews is clean.

A fix found by the final integration review does not, by itself, schedule another final review. Follow [When the Final Integration Review Finds an Issue](#when-the-final-integration-review-finds-an-issue).

### Final Full Integration Review

After the incremental-review cycle is clean, perform **one** fresh review of the **entire PR against its merge base**.

This is the final integration and regression sweep. Judge the final state of the PR as a whole rather than merely confirming individual fixes.

A full integration review continues across the changed subsystems and the integration paths they can reach even after an actionable defect has already been found. Finish that scope before submitting the review. See [Exhaust the Current Review Scope](#exhaust-the-current-review-scope). Several findings from that sweep still follow [When the Final Integration Review Finds an Issue](#when-the-final-integration-review-finds-an-issue). They do not, by themselves, schedule another unrestricted review of the entire PR.

If that review is clean, the automated review cycle can complete once applicable verification and any required Retail QA are documented. See Completion Standard.

### When the Final Integration Review Finds an Issue

Report and fix real issues normally. They are not optional because they appeared during the final sweep, because an earlier fix introduced them, or because the PR has already been reviewed several times.

After those fixes:

- Review the fixes incrementally.
- Inspect the callers, consumers, and state transitions the fixes directly affect.
- Perform the targeted integration sweep those changes require.
- Exhaust that incremental scope before submitting the re-review. See [Exhaust the Current Review Scope](#exhaust-the-current-review-scope).

Do **not** automatically require another unrestricted review of the entire PR merely because the previous final review found one or more issues.

Require another full review of the PR against its merge base only when the new fixes materially invalidate previous review coverage. Use the same conditions as [Fall Back to a Full Review When Review History Is Unreliable](#fall-back-to-a-full-review-when-review-history-is-unreliable). A narrow, well-tested fix discovered during the final sweep normally receives the targeted re-review above, not a restart of the whole review lifecycle.

There is no numeric cap on review rounds. Stop only when the applicable case in the Completion Standard is met. Do not stop because a defect was found late.

### Fall Back to a Full Review When Review History Is Unreliable

Do not guess about previously reviewed state. Perform a full review of the PR against its merge base when previous coverage can no longer reasonably be trusted, including when:

- the last reliably reviewed commit cannot be identified
- branch history was rewritten or force-pushed
- the merge base changed materially
- prior review context is unavailable or ambiguous
- the new work is a substantial architectural rewrite
- the new work adds a broad abstraction or state machine
- behavior changes are widespread
- the change crosses subsystems in a way that invalidates earlier conclusions
- another change invalidates assumptions made during earlier reviews

Incremental review is an efficiency optimization, not a reason to accept uncertainty about what has actually been reviewed. It is also not a reason to restart that full review after every fix.

---

## Review the Related Ticket

If the PR contains a linked **Ticket ID**, review that ticket before evaluating whether the implementation satisfies the request.

Use the ticket to understand:

- the original problem
- requirements and acceptance criteria
- expected user behavior
- documented edge cases
- architectural or product decisions
- later discussion that clarified or changed the request

Compare the PR against that context. A technically sound implementation can still be incorrect if it omits or contradicts a requirement.

Do not treat the ticket as authoritative in isolation. Consider it together with later discussion, the PR description, repository documentation, tests, and the current architecture. If the implementation intentionally differs from the ticket, look for evidence that the decision changed rather than automatically treating the difference as a defect.

If the linked ticket cannot be accessed, state that the ticket context could not be verified. Do not invent missing requirements.

---

## Inspect Before Assuming

Understand the existing architecture before judging or proposing changes.

Look for existing:

- sources of truth and ownership boundaries
- helpers and shared abstractions
- persistence and SavedVariables behavior
- addon communication and synchronization paths
- settings, defaults, and migrations
- lifecycle and event handling
- test infrastructure
- release, packaging, CI, and documentation conventions

Do not recommend duplicate state, parallel implementations, or new abstractions when the repository already has an authoritative mechanism.

If intent is unclear, use the code, tests, documentation, ticket/issue discussion, PR context, and repository history to resolve it when possible. Flag ambiguity only when it materially affects correctness and cannot reasonably be resolved from available evidence.

---

## Prioritize Correctness Over Polish

Focus findings on concrete, actionable problems such as:

- incorrect or incomplete behavior
- missed requirements
- regressions
- conflicting or duplicated sources of truth
- invalid state transitions or authority violations
- persistence, migration, reload, relog, or synchronization failures
- fresh-install or missing-state failures
- WoW API or lifecycle incompatibilities
- meaningful performance problems
- CI, packaging, versioning, release, or documentation-deployment errors
- tests that do not actually prove the behavior they claim to cover

Do not report these as actionable findings:

- cosmetic style preferences
- speculative concerns without a realistic failure path
- refactoring opportunities with no meaningful correctness or maintenance impact
- theoretical edge cases that cannot occur under the repository's actual constraints

When one of those is still worth tracking, label it as a follow-up consideration under [Actionable Findings and Follow-up Work](#actionable-findings-and-follow-up-work). Do not silently drop a useful observation, and do not promote it into mandatory PR scope.

---

## Actionable Findings and Follow-up Work

A review primarily evaluates the production state this PR would create. Separate defects that should block the PR from concerns that should normally become follow-up work.

### Actionable findings

Report these as blocking findings, including when they are found late or were introduced by a previous review fix:

- failure to satisfy the linked ticket or its acceptance criteria
- behavior the PR breaks
- regressions caused by the PR
- defects introduced by a previous review fix
- reachable invalid state transitions
- persistence or synchronization corruption
- authorization or trust-boundary failures
- privilege escalation
- credible data-integrity problems
- crashes, freezes, runaway execution, or meaningful UI-thread availability risks
- plausible user-facing failures
- other production-safety problems the PR causes or materially worsens

Do not downgrade one of these because the review round is late, because a previous fix caused it, or because repairing it is inconvenient. Severity still follows the impact table below. Review age is not a severity input.

### Follow-up considerations

These are normally not blocking requirements of the current PR:

- unrelated defects that clearly predate the PR and that the PR does not worsen or newly expose
- optional architecture cleanup
- refactoring with no concrete correctness consequence
- purely defensive hardening against scenarios with no credible impact
- speculative state combinations the repository and runtime cannot actually reach
- improvements that are useful but outside the problem this PR is changing

Do not drop them silently. When they are useful, identify them separately as follow-up work rather than mandatory PR scope.

A pre-existing problem becomes an actionable finding when the PR materially worsens it, newly exposes it, or cannot meet the requested change safely without fixing it.

---

## Credible Reachability

Every actionable finding needs a realistic failure path. A rare transition can still be a defect. A combination that cannot occur is not.

For a late-stage finding in particular, establish:

1. how the state is reached
2. which actor, event, or message triggers it
3. what incorrect behavior follows
4. whether repository and runtime constraints actually allow it
5. why the consequence matters

Do not reject a bug only because it is rare. Do distinguish a rare but credible production transition from a hypothetical combination that cannot happen.

---

## Review-Induced Complexity

Watch for a review process whose fixes add substantial new machinery, and whose later findings are mostly about that new machinery rather than the original implementation.

This matters most for state machines, synchronization, authorization, retries, caches, lifecycle handling, routing, persistence, and addon-message protocols.

When successive fixes keep creating new correctness issues inside the mitigation just added, consider whether the repair strategy itself has become too complicated. Evaluate whether a simpler approach would be safer, such as:

- simplifying the implementation
- consolidating duplicated state
- returning to an authoritative source of truth
- replacing layered special cases with a clearer invariant
- rolling back an overcomplicated mitigation
- splitting genuinely separate hardening into follow-up work
- documenting an architectural refactor for a later PR

This rule does not suppress a real defect. If the current code is wrong, report it. The rule is a reason not to answer every new finding by adding another guard, cache, tombstone, exception, or state variable onto an already unstable design.

---

## Addon State and Persistence

For stateful features, reason through more than the happy path. Where relevant, consider:

- a brand-new user with no profile or SavedVariables
- old SavedVariables and migrations
- `/reload`, logout/login, disconnects, and relogs
- partially initialized or missing state
- rebuilding derived state from authoritative data
- stale, duplicate, delayed, or out-of-order messages
- joining or leaving groups and raids
- players joining after synchronization already occurred
- different users holding different copies of synchronized state
- UI opened before expected state has been populated
- account-wide versus character-specific persistence

Determine which data is authoritative and verify ownership and precedence when multiple systems contain similar information.

Pending, cached, reconstructed, inferred, or remote data must not accidentally override authoritative state.

---

## WoW Runtime Behavior

Review code in the context of the World of Warcraft addon lifecycle, not merely as ordinary Lua.

Where relevant, inspect:

- nil or unavailable values during initialization
- event and load-order assumptions
- TOC dependencies and optional dependencies
- repeated or leaked frame/event registrations
- UI behavior on first open, reopen, `/reload`, and live state changes
- API availability, signatures, return values, and initialization timing
- deprecated or changed Retail APIs
- protected actions, combat lockdown, taint, and hardware-event requirements
- behavior outside the group, raid, zone, encounter, or feature context where code is expected to run
- addon-message limits, throttling, and communication volume

A feature that works only after the addon has accumulated normal runtime state is not sufficient if it can fail for a new user.

---

## Trust, Authority, and Addon Communications

Treat remote addon messages and synchronized state as trust boundaries.

Where relevant, verify:

- the sender is allowed to perform the requested action
- owner/admin/coordinator-only behavior is actually enforced
- message type, version, and payload are validated before state is mutated
- malformed, unexpected, stale, duplicate, or out-of-order messages fail safely
- pending or proposed state cannot become authoritative before the protocol allows it
- a remote client cannot overwrite authoritative local or coordinator state merely by sending a plausible message

Do not assume a message is valid simply because it arrived through the expected addon prefix or channel.

A finding can still block the PR when an intentionally malformed or hostile addon message can cause meaningful privilege escalation, unauthorized state mutation, data corruption, session-integrity failure, unbounded or repeatedly amplifiable UI-thread work, client freezing, or another meaningful availability impact.

Not every theoretical hostile-input hardening opportunity belongs in the current feature PR. Before treating adversarial behavior as a blocking defect, show the sender's actual capability, the reachable code, and the meaningful impact. Hardening with no demonstrated capability or impact is a follow-up consideration, not automatic scope.

---

## Performance

The addon may run for long play sessions. Treat frequently executed code as performance-sensitive.

Scrutinize:

- `OnUpdate` handlers and high-frequency events
- repeated full-table, roster, inventory, or equipment scans
- unnecessary allocations in hot paths
- repeated serialization/deserialization
- addon-message volume
- repeated UI rebuilds
- work performed while the relevant feature or UI is inactive
- work performed outside the context where it is needed

Prefer event-driven, cached, or incremental approaches when practical, but do not add complexity without a demonstrated correctness or performance benefit.

---

## Tests and Automated Verification

Passing tests are evidence, not the conclusion.

For important behavior:

- confirm tests exercise the real production path closely enough to prove the requirement
- check positive, negative, missing-state, and relevant transition paths
- ensure mocks and stubs do not bypass the logic actually at risk
- verify new regression tests would fail against the broken behavior they are intended to prevent
- look for meaningful regressions the existing suite would not detect

Run the relevant automated checks supported by the available environment.

If an applicable check cannot be run, state:

- what was not run
- why it could not be run
- what uncertainty remains

Do not imply that unexecuted checks were verified.

---

## Retail Verification

Automated tests do not prove behavior that depends on the live World of Warcraft client.

When relevant behavior cannot be realistically exercised by the repository's test environment, identify the specific Retail QA still required. Examples include:

- actual frame lifecycle behavior
- combat lockdown, taint, or protected-action restrictions
- Retail API timing
- live addon communication
- group or raid transitions
- UI interaction under real client state
- client performance or freezing
- Blizzard-controlled data or events

A missing live-client test is a **verification gap**, not automatically a defect. Do not report it as a bug without evidence of incorrect behavior.

Likewise, do not claim a feature is fully verified solely because automated tests pass when meaningful Retail-only behavior remains untested.

If required Retail QA remains, state that clearly and do not describe the PR as fully merge-ready until that QA is completed.

---

## CI, Packaging, Releases, and Documentation

Treat GitHub Actions, packaging, release automation, versioning, changelogs, and documentation deployment as production code.

Applicability decisions should use deterministic repository state whenever possible.

Verify both the path where an action should run and the path where it should intentionally skip, including distinctions such as:

- packaged/runtime changes
- documentation-only changes
- repository-guidance or development-only changes
- changes requiring a release or version bump
- changes that must not publish or alter release artifacts
- documentation changes that require deployment without addon publication

When an incorrect automated decision could publish, version, or promote the wrong artifact, prefer failing closed.

Do not use AI judgment for decisions that can be determined objectively from repository state.

---

## Evaluate Prior Review Feedback

Do not assume that a previous reviewer, automated tool, or AI-generated suggestion is correct.

Before reinforcing a previous finding or recommending its fix:

- verify that the problem exists in the current code
- check whether the implementation has compatibility or architectural reasons
- determine whether the suggestion would break existing behavior
- avoid adding unused abstractions or features merely because they appear more "proper"

If prior feedback is technically incorrect, stale, or incompatible with the repository's actual design, explain why rather than repeating it.

### Late findings must be new

Before reporting a finding on a PR that has already been reviewed, confirm it is genuinely new. Check whether it is:

- already fixed
- stale
- a duplicate of a resolved finding
- a restatement of a previously accepted design decision
- based on an assumption the current code contradicts

If the same underlying defect has regressed, report the regression. If the latest fix created a new failure mode, report that failure mode. Do not produce a "new" finding by reframing an issue that was already settled.

---

## Review Output

Lead with **actionable findings**, ordered by severity. Those are what must be fixed before the automated review cycle can complete. Submit the distinct high-confidence findings from the completed review scope together. Do not withhold an in-scope defect because another finding has already been written. See [Exhaust the Current Review Scope](#exhaust-the-current-review-scope).

For each actionable finding include:

1. **What is wrong**
2. **Where it occurs**
3. **Why it matters**
4. **A realistic trigger or failure scenario**
5. **The expected behavior or fix direction**

Reference the relevant file, function, workflow, state transition, or code path when possible.

A **follow-up consideration** is optional and comes after the actionable findings. Use it for a credible improvement or a problem worth tracking that this PR did not cause or materially worsen, and that is not required for the PR to be safe. Label it as follow-up. Do not mix it into the actionable list, and do not turn the review into an architecture report.

Keep these separate from findings:

- automated checks that were run
- checks that could not be run
- Retail QA still required
- other verification gaps

Do not repeatedly report resolved findings unless they have regressed.

If there are no actionable findings, say so directly and summarize only the verification status that matters. A follow-up consideration may still be listed. Avoid padding a clean review with speculative suggestions or an unnecessary restatement of the PR.

---

## Severity

| Severity | Use when |
| --- | --- |
| **Critical** | Data corruption, severe production breakage, unsafe release behavior, destructive synchronization errors, or broadly unusable core functionality |
| **High** | Likely user-facing defects, significant correctness failures or regressions, common workflow failures, or serious persistence/synchronization problems |
| **Medium** | Real defects with narrower impact, less common triggers, recoverable state problems, or meaningful non-critical workflow failures |
| **Low** | Concrete limited-impact defects or narrow maintainability risks with a realistic consequence |

Do not inflate severity. A severe-sounding hypothetical is not high severity unless its triggering conditions are plausible in this repository. Do not lower severity because a defect was found late, because a previous review fix introduced it, or because the PR has already had several reviews.

---

## Completion Standard

The automated review cycle is complete in one of these cases. There is no numeric limit on rounds, and a real defect does not expire. Several actionable findings in one review do not change these cases. Fix them, then continue with the incremental or targeted review the case already requires. Do not schedule another whole-PR review only because more than one finding was reported.

### Case A — The initial review is clean

- The initial full review finds no actionable findings.
- Applicable automated checks have been run, or unavailable checks are explicitly identified.
- Any required Retail QA is documented.
- The automated review cycle is complete.

### Case B — The initial review finds issues

- Fix the actionable findings.
- Repeat incremental review until an incremental review is clean.
- Perform one final full integration review.
- If that final review is clean, document verification and any required Retail QA. The automated review cycle may then complete.

### Case C — The final full integration review finds an issue

- Fix the actionable issues found in that review.
- Incrementally review those fixes, including a targeted integration sweep of the behavior they affect.
- If that review is clean, document verification and any required Retail QA. The automated review cycle may then complete.
- If that targeted review finds further actionable issues, fix them and repeat the targeted review of that new scope. Do not schedule another whole-PR review unless the latest fixes materially invalidated prior review coverage.
- Require another whole-PR review only when those fixes materially invalidated prior review coverage, using the conditions in [Fall Back to a Full Review When Review History Is Unreliable](#fall-back-to-a-full-review-when-review-history-is-unreliable).

In every case:

- applicable automated checks must have been run, or unavailable checks must be explicitly identified
- any required Retail-only verification must be clearly documented
- unresolved verification gaps must not be presented as verified behavior

Automated review completion does not by itself mean the PR is merge-ready when required Retail QA remains. Retail QA stays required whenever the repository's existing policy requires it.

The purpose of this process is to provide a disciplined, evidence-based answer to one question:

**Is this pull request safe to become the new production state of the repository, and what—if anything—still needs verification before merge?**
