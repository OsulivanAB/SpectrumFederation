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
- `SF.GuildGossip:NotifyProviderChanged(id)` via `SF.GuildGossip.NotifyProviderChanged`
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
| Partial reassembly | ≤4 messages, ≤4 KiB each, ≤16 KiB total; idle expiry 30s |
| Complete recv queue | ≤4 messages / 16 KiB |
| Discovery | initial 3–10s jitter; then 120–180s |
| View idle timeout | 120s usable-work time without page progress |
| Page retries | 2 resends (5s then 15s); then ≥60s peer cooldown |

## C1 paging (brief)

Providers maintain a 64-bucket read index. A pull captures per-bucket end markers (last sequence, count, fingerprint). Manifests seek `afterSeq < seq ≤ endSeq`. Appends assign later sequences and set one follow-up dirty flag; they do not restart the current pass. Bookmarks are scoped by peer/provider/scope/bucket and invalidated on epoch/scope/eligibility changes.

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

## Handoff to Phase 2 / 3

- Transport does not authenticate `author` / rank / admin fields on relayed records.
- Guild scope inputs: `IsInGuild`, `GetGuildInfo("player")`, optional `C_Club.GetGuildClubId()`, roster via `GUILD_ROSTER_UPDATE`.
- Providers own durable storage and reload recovery; engine bookmarks are runtime-only.
- Do not store synthetic provider records in production Guild Supplies SavedVariables.
