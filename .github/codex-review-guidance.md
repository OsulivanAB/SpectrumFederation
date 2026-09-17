# Codex Pull Request Review Guidance

This document defines the expected behavior for Codex pull request reviews in this repository.

The goal is to determine whether a pull request is safe to become the new production state of the repository without creating unnecessary review churn. Prioritize correctness, regressions, integration risk, runtime behavior, persistence, synchronization, performance, release safety, and meaningful verification over cosmetic preferences.

---

## Review Principles

Act as a senior engineer protecting production quality, not as a style checker.

- Inspect before assuming.
- Verify important claims against the repository rather than trusting the PR description, implementation summary, comments, or passing tests.
- Trace important behavior to its source of truth.
- Review impact across subsystem boundaries when a change can affect callers, consumers, persisted data, synchronization, settings, UI, tests, packaging, release behavior, or documentation.
- Prefer a small number of well-supported findings over a large list of weak possibilities.
- If there are no meaningful findings, say so. Do not manufacture issues to produce review output.

---

## Review Lifecycle

Use a staged review process so fixes receive focused review while the completed PR still receives a full integration sweep.

### Initial Review

On the first review of a PR:

- Review the **entire PR against its merge base**.
- Evaluate the implementation as a whole, including relevant production code, tests, configuration, workflows, persistence, documentation, and integration points.
- Review the related ticket when one is provided.
- Establish the initial set of actionable findings.

Do not limit the initial review to the newest commit or the files emphasized by the PR description.

If the initial full review has no actionable findings, no additional full review is required solely for process reasons. Complete the applicable automated verification and document any remaining Retail QA.

### Subsequent Reviews

After fixes or other new commits are pushed:

- Identify the last commit that was reliably reviewed.
- Review the commits added since that point.
- Verify that previous findings were actually resolved.
- Follow changed behavior through callers, consumers, shared state, persistence, communications, and other affected code as needed.
- Do **not** routinely re-audit unrelated unchanged portions of the PR.
- Do not restrict investigation to changed lines when understanding their consequences requires inspecting code elsewhere.

If an actionable issue is found, report it and repeat incremental review after the next fix.

### Final Full Review

After an incremental review finds **no actionable issues**, perform a fresh review of the **entire PR against its merge base**.

This is the final integration and regression sweep. Judge the final state of the PR as a whole rather than merely confirming individual fixes.

If the final full review finds an actionable issue:

1. report it normally
2. after it is fixed, return to incremental review
3. once the incremental review is clean, perform another final full review

The cycle is complete when the required full review is clean and applicable verification has been accounted for.

### Fall Back to a Full Review When Review History Is Unreliable

Do not guess about previously reviewed state. Perform a full review when:

- the last reliably reviewed commit cannot be identified
- branch history was rewritten or force-pushed
- the merge base changed materially
- prior review context is unavailable or ambiguous
- a cross-cutting change invalidates assumptions made during earlier reviews

Incremental review is an efficiency optimization, not a reason to accept uncertainty about what has actually been reviewed.

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

Do not report:

- cosmetic style preferences
- speculative concerns without a realistic failure path
- refactoring opportunities with no meaningful correctness or maintenance impact
- theoretical edge cases that cannot occur under the repository's actual constraints

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

---

## Review Output

Lead with actionable findings, ordered by severity.

For each finding include:

1. **What is wrong**
2. **Where it occurs**
3. **Why it matters**
4. **A realistic trigger or failure scenario**
5. **The expected behavior or fix direction**

Reference the relevant file, function, workflow, state transition, or code path when possible.

Keep these separate from findings:

- automated checks that were run
- checks that could not be run
- Retail QA still required
- other verification gaps

Do not repeatedly report resolved findings unless they have regressed.

If there are no actionable findings, say so directly and summarize only the verification status that matters. Avoid padding a clean review with speculative suggestions or an unnecessary restatement of the PR.

---

## Severity

| Severity | Use when |
| --- | --- |
| **Critical** | Data corruption, severe production breakage, unsafe release behavior, destructive synchronization errors, or broadly unusable core functionality |
| **High** | Likely user-facing defects, significant correctness failures or regressions, common workflow failures, or serious persistence/synchronization problems |
| **Medium** | Real defects with narrower impact, less common triggers, recoverable state problems, or meaningful non-critical workflow failures |
| **Low** | Concrete limited-impact defects or narrow maintainability risks with a realistic consequence |

Do not inflate severity. A severe-sounding hypothetical is not high severity unless its triggering conditions are plausible in this repository.

---

## Completion Standard

The automated review cycle is complete when either:

- the **initial full review** has no actionable findings; or
- after fixes, the latest **incremental review is clean** and the subsequent **final full review is clean**.

In either case:

- applicable automated checks must have been run, or unavailable checks must be explicitly identified
- any required Retail-only verification must be clearly documented
- unresolved verification gaps must not be presented as verified behavior

Automated review completion does not by itself mean the PR is merge-ready when required Retail QA remains.

The purpose of this process is to provide a disciplined, evidence-based answer to one question:

**Is this pull request safe to become the new production state of the repository, and what—if anything—still needs verification before merge?**
