# SpectrumFederation Bugbot Review Rules

Review this repository as a World of Warcraft Retail addon where client
stability and bounded execution are first-class correctness requirements.

Prioritize real production defects. Do not spend findings on style, naming,
formatting, cosmetic cleanup, speculative refactors, or unrelated unchanged
code.

## Evidence threshold

Report a finding only when there is a credible path from the changed code to
the failure.

For each finding:

1. Identify the triggering condition.
2. Trace the relevant execution or state path far enough to establish that the
   problem is reachable.
3. Explain the resulting failure or user-visible impact.
4. Point to the changed code responsible.
5. Prefer the root cause over multiple comments describing symptoms of the same
   defect.

Do not assume that recurring code, a timer, an event handler, a callback, or an
allocation is inherently a performance bug. Establish frequency, lifecycle,
termination, cleanup, and practical impact.

Do not repeat another reviewer's finding unless it remains unresolved or the
current code introduces materially new evidence.

## World of Warcraft runtime

Runtime addon code executes in Blizzard's embedded Lua 5.1 environment.

Do not recommend:

- Lua 5.2+ syntax or semantics;
- filesystem or arbitrary file I/O;
- sockets;
- external processes;
- unavailable standard-library facilities;
- UI techniques that would introduce protected-action taint.

Give especially high scrutiny to code that can execute on the WoW UI thread.

Look for credible cases of:

- callback recursion;
- event feedback loops;
- layout or `OnSizeChanged` feedback loops;
- high-frequency or permanently active `OnUpdate` handlers;
- timers or tickers that survive after their useful lifecycle;
- duplicate event/listener registration;
- queues that fail to drain;
- retry or inspection storms;
- addon-message amplification;
- repeated full rebuilds or scans;
- unbounded synchronous work;
- long-session allocation/resource growth;
- large synchronous SavedVariables processing;
- errors hidden in a way that leaves broken state active.

Idle features should become genuinely idle. Repeated lifecycle operations such
as opening, closing, enabling, disabling, refreshing, joining, leaving, or
changing profiles should converge rather than accumulate work.

## Asynchronous game data

Where the change depends on item data, inspection, roster state, unit identity,
or other asynchronous game information, check for:

- delayed availability;
- stale callbacks;
- changed identities between request and completion;
- invalidated state;
- retry termination;
- cancellation or cleanup when the consumer disappears.

Do not assume game data is synchronously available merely because it often is.

## Persistence and profiles

For SavedVariables, configuration, or profile changes, check compatibility with
existing installed-user data.

Consider:

- missing fields;
- old fields;
- changed defaults;
- migrations;
- profile switching;
- profile deletion;
- stale values;
- serialization boundaries;
- partial or previously persisted state.

A clean install is not sufficient evidence of compatibility.

## Synchronization and communications

For synchronization, addon messages, shared records, or distributed state,
check:

- sender authorization;
- sender identity;
- deduplication;
- ordering;
- stale updates;
- retries;
- echo/feedback behavior;
- amplification;
- duplicate authoritative-record creation;
- convergence after duplicate or reordered messages.

A duplicate event or message must not create duplicate authoritative state.

## UI lifecycle

For UI changes, inspect:

- shared consumers;
- re-entrancy;
- repeated open/close cycles;
- repeated refresh/layout cycles;
- handler registration and cleanup;
- frame ownership;
- applicable combat restrictions;
- protected UI and taint risks.

A fix for one panel must not destabilize shared UI infrastructure.

## User-visible recurring output

Check whether unchanged state can repeatedly emit the same warning, message, or
notification.

Prefer output tied to meaningful state transitions or appropriate
deduplication/rate limiting. Do not recommend suppressing useful errors merely
to make output quiet.

## Optional integrations

Optional child addons and third-party integrations must remain optional.

Inspect bundled or third-party code when necessary to understand an integration
contract, but do not critique unrelated unchanged vendored code.

Prefer existing repository adapters, helpers, and lifecycle patterns over
parallel implementations unless the existing abstraction is demonstrably
incorrect for the change.

## Release safety

When TOCs, workflows, packaging, promotion, rollback, or release scripts change,
check:

- beta-first branch behavior;
- version consistency;
- parent/child addon version synchronization where required;
- artifact contents;
- release conditions;
- permissions;
- promotion safety;
- rollback behavior.

Do not claim that WoW Retail testing occurred unless the PR contains evidence
that a human performed it.