# Issue refinement, planning, and implementation

Load this for issue refinement, feature work, bug diagnosis, architecture
decisions, and repair batches. Runtime detail lives in
`SpectrumFederation/AGENTS.md`; this file is the working procedure.

## 1. Inspect before prescribing

- Read the actual issue/PR, linked discussions, current production paths,
  callers, consumers, tests, lifecycle, persisted data, and integration
  boundaries. The ticket's suggested mechanism is a hypothesis, not a spec:
  for a bug, establish the real cause.
- Distinguish observations, supported inferences, assumptions, and missing
  evidence in your working notes; keep them distinct in user-facing reports.
- Refresh the branch before writing if another actor changed it; never
  overwrite their work. Reassess if the base moved.

## 2. Issue refinement mode (planning)

Make the issue an engineering contract. Cover, as applicable:

- Problem and observable desired behavior.
- Locked decisions/invariants, scope, and explicit non-goals.
- Material lifecycle cases (fresh install, old SavedVariables, reload,
  reconnect, profile switch, mixed versions where relevant).
- Implementation guidance grounded in existing mechanisms.
- Testable acceptance criteria, automated validation from the canonical map,
  and the human Retail checks still required.

Ask the owner about consequential ambiguity in behavior, ownership,
persistence, compatibility, trust, or success semantics. Let repository
evidence settle routine implementation choices — do not ask what the code can
answer.

## 3. Change contract for technically risky work

Required when work introduces or materially changes shared/persisted state,
caches or derived state, queues, retries, reservations, deferred work,
asynchronous side effects, cross-client synchronization or protocol
semantics, shared UI infrastructure, or recurring runtime work — regardless
of ticket size. A few sentences in task context suffice:

- **Authority:** which component/client owns the source of truth?
- **Guarantee:** what observable invariant must remain true?
- **Dependencies:** what invalidates a cached or pending decision?
- **Lifecycle:** success, failure, cancellation, expiry, reload, ownership
  transfer, version mismatch — as relevant.
- **Evidence:** which focused automated and Retail checks establish it?

Reuse and update an existing contract for repair work instead of
reconstructing the feature. Ordinary local fixes need no ceremony; no separate
design document, planning agent, or approval cycle. If satisfying a requested
guarantee needs materially different architecture or a product trade-off,
escalate before building more machinery — do not silently weaken the
requirement.

For features that will span milestones, make a short initial assessment of
source-of-truth ownership, durable state, lifecycle risks, and verification,
and propose coherent milestones before building a large dependency chain.
Bring forward targeted Retail checks before later work depends on uncertain
trade, bank, combat, or WoW API behavior.

## 4. Implementation order

Work through dependencies in a sensible order:

1. Domain invariants and state ownership.
2. Persistence, defaults, and migrations.
3. Authority, synchronization, and external adapters.
4. Controller/feature behavior.
5. UI.
6. Tests and documentation.

Preserve user edits and other actors' changes. Keep the change targeted:
extend existing identity, authorization, settings, persistence, sync,
logging, retry, UI, and integration mechanisms. Avoid parallel systems,
speculative extensibility, unrelated cleanup, new always-on background work,
and new third-party libraries unless explicitly requested. When layers of
guards, caches, tombstones, trackers, or state machines keep creating more
problems, reconsider the invariant and a simpler architecture instead of
adding another patch layer.

Regression-first or test-first where practical. Debugging and additional
edits inside an authorized implementation/repair batch need no per-edit
approval; prefer coherent batches but allow further pushes needed to finish
the authorized work correctly.

## 5. Runtime, state, and lifecycle checklist

The addon runs in WoW Retail's embedded Lua 5.1 sandbox on the UI thread. No
Lua 5.2+ syntax; no filesystem, sockets, or external processes; follow the
`local addonName, SF = ...` namespace pattern; avoid globals; prefer
`hooksecurefunc`; respect combat lockdown and protected actions. Verify
changing WoW APIs, event behavior, item classifications, and material
external contracts (e.g. TSM via `SF.TSM`) from current authoritative sources;
never guess seasonal IDs or assume old Retail behavior. Full rules:
`SpectrumFederation/AGENTS.md`.

Check, when relevant:

- One authoritative owner per state; distinguish local preferences, shared
  configuration, durable records, derived views, and transient transport
  state. Missing ≠ zero; unknown ≠ false; partial ≠ complete; attempted ≠
  successful; queue admission ≠ submission ≠ remote acceptance.
- Fresh installs, old SavedVariables, missing fields, defaults, migrations,
  `/reload`, relog, disconnect/reconnect, profile switch/delete/sync,
  initialization and load order. Never reset existing configuration merely to
  fill new defaults.
- Sender identity and authority, payload/version validation, malformed
  messages, duplicates, stale/out-of-order delivery, fresh joins, ownership
  changes, mixed versions where applicable, replay and rebroadcast
  amplification. The expected addon channel/prefix is not proof of trust.
  Prefer idempotent authoritative effects; dedupe keys must not collapse
  legitimate repeated events.
- UI visibility vs feature enablement vs synchronization: hiding a window
  must not silently change the domain contract.
- Cache scope, all invalidations, incomplete data, ownership/reset behavior,
  and reuse-plus-reevaluation tests.
- Retry cadence, concurrency, memory, cancellation, freshness, retained
  obligations. A fixed retry count must not silently discard required work; a
  timeout does not prove an external side effect failed; indefinite retries
  need a real remaining obligation and lifecycle boundary.
- Event/callback/resize/layout/show-hide feedback loops; listeners, timers,
  tickers, and frames accumulating across repeated operations; queues that do
  not drain; inspection/message storms; high-frequency full scans/rebuilds;
  serialization and large synchronous SavedVariables work.

Idle features become idle; repeated lifecycle operations converge. Genuine
time slicing returns control between slices; a bounded inner loop inside a
synchronous outer loop is not yielding. Support performance claims with a
credible mechanism, proportionate cost analysis, or focused measurements —
an obvious runaway path needs no benchmark, and ordinary repeated work is not
automatically a freeze. Do not add complex optimization machinery without
evidence.

## 6. Project integration map

- `SpectrumFederation/`: parent addon. Initialization in
  `SpectrumFederation.lua`; common helpers under `modules/`; TOC-defined load
  order.
- `SpectrumFederation_CursedSurgeTracker/`,
  `SpectrumFederation_RCLootCouncilIntegration/`: optional child addons in the
  release zip; keep them optional.
- Settings: `modules/Settings/Schema.lua`, `Store.lua`, `Apply.lua`,
  `modules/UI/Settings/`. Reuse Registry/PageBuilder/controls/navigation; new
  pages use `categoryId` (`parentId` is a legacy alias). Check shared
  consumers and re-entrancy for Section, layout, ScrollFrames, sizing, or
  refresh infrastructure. Domain skill: `.cursor/skills/settings-ui-change/SKILL.md`.
- TradeSkillMaster: only through `SF.TSM` in `modules/Integrations/TSM.lua`;
  never direct feature-level `TSM_API` calls or TSM internals. Optional,
  read-only, demand-driven; distinguish real zero from nil. Domain skill:
  `.cursor/skills/tsm-integration/SKILL.md`.
- Guild Gossip and Guild Supplies: load the nested `AGENTS.md` contracts and
  current docs before touching them; preserve provider/transport ownership
  and accounting boundaries. Do not copy schema numbers or feature-phase
  decisions into this skill.
- Diagnostics: `SF.Debug` with existing call signatures, including feature/
  action lifecycle and failure logging; never hot-path spam.
