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
3. D1 NORMAL/SLOW thresholds; missing/invalid FPS ⇒ SLOW; steady low FPS still makes bounded progress; combat/loading pauses preserve unfinished needs.
4. Aggregate work/queue/peer/receive/reassembly limits across providers; one initiated pull and one served pull per client; stop-and-wait paging.
5. Queue acceptance ≠ final-fragment submission ≠ remote receipt ≠ provider acceptance.
6. Independent of raid/session/Loot Helper enablement/UI/profiles/coordinators.
7. Chat-free: enabled `SF.Debug` only. Synthetic provider disabled by default; no active provider ⇒ no recurring work.

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

Production-Lua multi-peer harness (`tests/lua/guild_gossip_tests.lua`) plus packaging/lint/docs validation. Retail smoke remains human QA.
