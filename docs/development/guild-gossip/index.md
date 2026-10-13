# Guild Gossip Infrastructure (Phase 1)

Phase 1 delivers a reusable, bounded, low-priority **guild gossip transport** with an append-only synthetic provider. It does **not** connect Guild Supplies, migrate SavedVariables, or alter raid Consumables authority. Follow-up: Phase 2 domain work (#384 / #385–#386) and Phase 3 activation (#379 / #387–#389).

Issue contract: [#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378).

## Change contract (summary)

| Concern | Owner |
| --- | --- |
| Durable records, dedupe, conflicts, pending, storage | Provider |
| Eligibility / shareable summaries | Provider (fail closed) |
| Discovery, whisper transport, C1 cursors/bookmarks | Gossip engine (runtime-only) |
| AceComm multipart size/lifetime for `SF_GG` | Receive guard on LibStub-selected AceComm |
| Shared send admission / foreground precedence | `LootHelperComm` traffic class |

Read sequences are **transport cursors only**. They are never authoritative event order, transaction identity, campaign boundaries, or admin revisions.

## Provider API

Register through `SF.GuildGossip`:

```lua
SF.GuildGossip:Register({
  id = "my.feature",
  schema = 1,
  enabled = true,
  ready = true,
  GetScopeId = function()
    return SF.GuildGossip.GetGuildScopeId()
  end,
  IsPeerEligible = function(peerName, ctx)
    return SF.GuildGossip.IsGuildMember(peerName)
  end,
  GetCapabilities = function()
    return { feature = true }
  end,
  ListRecordIds = function()
    return { "r1", "r2" }
  end,
  GetRecordVersionFp = function(recordId)
    return "v1"
  end,
  GetRecordBody = function(recordId)
    return { id = recordId, versionFp = "v1", body = { ... } }
  end,
  ValidateAndApply = function(record, ctx)
    -- ctx.sender is the normalized transport sender (untrusted author fields)
    -- return "accepted" | "duplicate" | "rejected" | "pending"
    return "accepted"
  end,
})
```

 complementary helpers:

- `SF.GuildGossip:Unregister(id)` / `:EnableProvider` / `:DisableProvider`
- `SF.GuildGossip.NotifyProviderChanged(id)` dirties the provider index for a bounded rebuild and reopens affected discovery coverage
- `SF.GuildGossip:EnableSynthetic(opts)` / `:DisableSynthetic(id)` — **explicit** test activation; disabled by default; runtime-only store
- `SF.GuildGossip:GetStats()` — runtime diagnostics

Delivery results distinguish **accepted**, **duplicate**, **rejected**, and **pending**. Queue acceptance, final-fragment submission, remote receipt, and provider acceptance are different states.

## Protocol and encoding

- Prefix: `SF_GG` (independent of `SF_LH` / `SF_LHB`)
- Gossip protocol version: `1` (independent of raid SyncProtocol v9)
- Encoding: uncompressed `B64CBOR` only (`NONE` for empty control envelopes)
- Compressed `B64CBORZ` gossip is **rejected before decompression**
- Distributions: small `GUILD` discovery; scoped `WHISPER` for views/manifests/bodies

## Operational limits (D1 initial contract)

| Limit | Value |
| --- | --- |
| FPS mode | Missing/invalid ⇒ SLOW; enter SLOW below 30 for 2s; return NORMAL at ≥40 for 5s; band preserves mode |
| Step cadence | NORMAL 0.1s / SLOW 1.0s |
| CPU target / step | NORMAL 0.5ms / SLOW 0.25ms |
| Incoming applies / step | NORMAL 8 / SLOW 1 |
| Index entries / step | NORMAL 64 / SLOW 8 |
| Manifest entries / message | NORMAL 32 / SLOW 4 |
| Bodies / message | NORMAL 8 / SLOW 1 |
| Encoded envelope | ≤4 KiB; discovery ≤240 bytes |
| Record CBOR | ≤2 KiB |
| Concurrent pulls | 1 out + 1 in; stop-and-wait pages |
| Admitted out bytes | ≤8 KiB unfinished gossip into lower-level send path |
| Peer working set | ≤64; expire 10 minutes; never evict active exchange |
| Partial reassembly | ≤4 messages, ≤4 KiB each, ≤16 KiB total, ≤32 fragments; idle expiry 30s; physical AceComm spool cleared with accounting |
| Complete recv queue | ≤4 encoded messages / 16 KiB (decode deferred until dispatch) |
| Discovery | initial 3–10s jitter; then 120–180s; rotated provider subsets when over 240 bytes |
| View idle timeout | 120s usable-work time (pause excluded) without page progress; served views use the same lease |
| Page retries | 2 resends of the outstanding correlated request (5s then 15s); then ≥60s peer cooldown |
| Unresolved obligations | ≤64 entries, 600s TTL; unresolved views are not marked covered |
| Foreground reservation | Comm reserves queue/per-target capacity for FOREGROUND; BACKGROUND may be evicted |
| Record CBOR / body pages | ≤2 KiB raw CBOR per record; BODY/MANIFEST pages packed to the 4 KiB encoded envelope |

## Guarantees hardened in the #390 repair batch

Locked architecture is unchanged: C1/D1, uncompressed `B64CBOR`, raid independence, synthetic-only default, and strict no-chat.

1. **Partial body retention** — NORMAL→SLOW keeps the admitted BODY subpage and a per-subpage apply cursor; enumeration advances only after the subpage is settled.
2. **Request correlation** — MANIFEST/BODY responses must match `requestId` / `subpage` / expected IDs+fingerprints; stale or duplicate pages neither apply nor refresh leases.
3. **Usable-time leases** — Outgoing and served pulls expire on usable time; retries replay the outstanding phase request; backoff is enforced; combat/loading pauses do not burn the lease.
4. **Physical reassembly bounds** — ReceiveGuard clears `multipart_spool` on reject/expiry and bounds empty non-progress fragments.
5. **Admit-before-decode** — Encoded envelopes are queued after cheap sender/channel/size/proto checks; decode and schema validation run under the shared step budget.
6. **Dirty-driven index + idle** — Completed indexes are not re-listed every step; seeks start after the cursor; aggregate index/app budgets are shared; the 0.1s ticker stops when truly idle (discovery keeps its own timer).
7. **Cancel unsent work** — Provider disable/unregister and runtime invalidation cancel scoped Comm queue items and release admission; eligibility/scope are rechecked before export, send, and apply.
8. **Fresh source epochs** — `CreateIndex` / rebuild / re-registration mint a new epoch via a process-wide counter; bookmarks require matching epoch+scope.
9. **Unresolved without false coverage** — PENDING/REJECTED records stay in a bounded unresolved map and block `peer.covered` for that provider until reconciled or expired.
10. **Byte-aware pages** — Servers pack BODY/MANIFEST pages to the encoded cap and skip oversize records rather than failing the whole response silently.
11. **Provider scopes** — Both directions use `GetScopeId()` (not only guild identity) and pass peer/scope context into eligibility.
12. **Foreground protection** — BACKGROUND admission leaves reserved FOREGROUND capacity; FOREGROUND may evict BACKGROUND at both global and per-target caps.
13. **Fair discovery** — When capabilities exceed 240 bytes, announcements rotate which providers fit rather than permanently trimming the same tail.

## C1 paging (brief)

Providers maintain a 64-bucket read index. A pull captures per-bucket end markers (last sequence, count, fingerprint). Manifests seek `afterSeq < seq ≤ endSeq` with direct position lookup. Appends update the live index and set one follow-up dirty flag; they do not restart the current pass or force a full history re-list. Bookmarks are scoped by peer/provider/scope/bucket and invalidated on epoch/scope/eligibility changes.

## Retail smoke test (human)

Automated tests do **not** replace Retail QA.

1. Two or more guild characters on Retail with this build.
2. Enable Debug if you want transport diagnostics: existing Debug UI / settings.
3. On each client, activate the synthetic provider explicitly, for example via an authorized debug/dev console snippet:
   ```lua
   SF.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip" })
   local p = SF.GuildGossip.GetProvider("sf.synthetic.gossip")
   -- append a few records through the provider API used in tests / slash if exposed
   ```
   Prefer the documented public API (`EnableSynthetic` / provider `AppendLocal` when available on the returned object).
4. Confirm characters are in the same guild and roster-ready (`/reload` then wait for guild roster).
5. Observe silent operation in normal Chat (no gossip Chat lines). With Debug enabled, expect `GUILD_GOSSIP` category lines only.
6. Append disjoint synthetic records on each client; wait through discovery jitter; confirm eventual convergence of synthetic stores.
7. Repeat while in a raid/Loot Helper session — gossip must continue independently.
8. Cleanup:
   ```lua
   SF.GuildGossip:DisableSynthetic("sf.synthetic.gossip")
   ```
9. Cross-realm same-guild members should discover via `GUILD` addon messages. Opposite-faction whispers remain a Blizzard availability constraint; exchanges may time out safely and retry later — do not treat that as engine authority failure.

## Evidence

- Production-Lua multi-peer harness: `tests/lua/guild_gossip_tests.lua`
- Owner-review repair regressions: `tests/lua/guild_gossip_repair_tests.lua` (fail on reviewed head `aa6fa91`, pass after repair)
- Packaging/lint/docs validation per root `AGENTS.md`
- Retail smoke remains human QA

## Handoff to Phase 2 / 3

- Transport does not authenticate `author` / rank / admin fields on relayed records.
- Guild scope inputs: `IsInGuild`, `GetGuildInfo("player")`, optional `C_Club.GetGuildClubId()`, roster via `GUILD_ROSTER_UPDATE`.
- Providers own durable storage and reload recovery; engine bookmarks are runtime-only.
- Do not store synthetic provider records in production Guild Supplies SavedVariables.
