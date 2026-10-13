# Guild Gossip Phase 1 — Change Contract (#378)

Zip-excluded guidance (`*/AGENTS.md`). Canonical provider API and Retail smoke steps live in `docs/development/guild-gossip/`.

## Authority

| Concern | Owner |
| --- | --- |
| Durable records, identities, dedupe, conflicts, pending outcomes, storage | Registered **provider** |
| Eligibility / peer filtering / shareable summaries | **Provider** (engine fails closed when unknown) |
| Discovery, whisper transport, pacing, C1 seek cursors/bookmarks | **Guild Gossip engine** (runtime-only) |
| AceComm multipart reassembly size/lifetime for `SF_GG` | **ReceiveGuard** on the LibStub-selected AceComm instance |
| Shared send admission / foreground precedence | **LootHelperComm** traffic-class queue |

## Guarantees

1. C1 fixed source-local end markers + seek cursors over a 64-bucket read index; appends dirty a follow-up pass and never move the current finish line.
2. Read sequences are transport cursors only — never authoritative event order, txn identity, campaign boundaries, or admin revisions.
3. D1 NORMAL/SLOW thresholds; missing/invalid FPS ⇒ SLOW; steady low FPS still makes bounded progress; combat/loading pauses preserve unfinished needs and do not consume view leases.
4. Aggregate work/queue/peer/receive/reassembly limits across providers; one initiated pull and one served pull per client; stop-and-wait paging with requestId/subpage correlation and byte-aware pages.
5. Queue acceptance ≠ final-fragment submission ≠ remote receipt ≠ provider acceptance; unsent gossip is cancellable by provider/runtime invalidation.
6. Independent of raid/session/Loot Helper enablement/UI/profiles/coordinators.
7. Chat-free: enabled `SF.Debug` only. Synthetic provider disabled by default; no active provider ⇒ no recurring work.
8. Admit encoded gossip before decode; validate bounded structures + distributions before mutation; physical AceComm spool is released with guard accounting, including during pause via an independent expiry timer.
9. Index maintenance is dirty/incomplete-driven; incomplete work prevents idle; discovery rotates oversized capability announcements and advertises per-provider `changeGen`.
10. Provider `GetScopeId` is authoritative on both request and serve paths; optional `IsRecordExportable` supplies peer-specific export filtering; unresolved obligations never mark a view covered.
11. Transport outcomes are explicit: admission ≠ final submission ≠ acceptance; cancel/fail frees leases; backoff is real; offer replay is idempotent for the same correlated VIEW.

## Dependencies / invalidation

- Guild readiness (membership roster + stable guild scope) required for discovery/exchange.
- Provider disable/unregister, scope/eligibility/index epoch change, or guild change invalidates affected views/bookmarks.
- Genuine view invalidation (not ordinary appends) interrupts the current pass.

## Lifecycle

```
no provider → idle
provider ready → discovery (jittered) + opportunistic pulls
combat/loading → pause expensive work; retain unfinished needs
recovery → 3–10s jitter then NORMAL/SLOW pacing
unregister/shutdown → clear runtime queues/callbacks; leave provider durable data alone
```

## Evidence

- Production-Lua multi-peer harness: `tests/lua/guild_gossip_tests.lua`
- Owner-review regression probes (fail on reviewed head `aa6fa91`, pass after repair): `tests/lua/guild_gossip_repair_tests.lua`
- Packaging/lint/docs validation per root `AGENTS.md`
- Retail smoke remains human QA
