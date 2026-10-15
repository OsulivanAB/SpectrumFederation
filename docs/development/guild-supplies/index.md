# Guild Supplies Foundation (Phase 2A)

Part 2A delivers a **dormant, guild-keyed staged foundation** for Guild Supplies. It does **not** migrate SavedVariables, register a gossip provider, capture bank context, reset campaigns, add Settings pages, or activate live guild-wide writes.

Issue contract: [#385](https://github.com/OsulivanAB/SpectrumFederation/issues/385). Parent roadmap: [#384](https://github.com/OsulivanAB/SpectrumFederation/issues/384). Transport dependency: [#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378).

**Hard release invariant:** Legacy profile-scoped Consumables remains the only live authoritative writer until [#389](https://github.com/OsulivanAB/SpectrumFederation/issues/389).

## Change contract (summary)

| Concern | Owner |
| --- | --- |
| Durable staged guild record / schema validation | `SF.GuildSupplies` (`State`) |
| Verified current guild/rank capabilities | `Authority` via demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` |
| Operation IDs, typed validation, staged admission | `Operations` |
| Live donation ledger / bank verification | Legacy Consumables (unchanged) |
| Gossip transport / discovery | Guild Gossip (no Guild Supplies provider in 2A) |

## Saved schema

Root under the existing account SavedVariables:

```lua
SpectrumFederationDB.guildSupplies = {
  schemaVersion = 1,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<actual club id>"] = {
      schemaVersion = 1,
      activation = "staged", -- #385 never sets active
      datasetId = "gs1:<guid>:<nonce>:<seq>",
      permission = { editorRankPosition = 3, revisionId = "<datasetId or op id>" },
      currentCampaignId = nil,
      campaigns = { -- [campaignId] = immutable boundary header },
      accounting = {
        _consumables = { guild = { guid, name, realm }, bankTab, requestedItems, ... },
        _consumableEvents = {},
        _consumableEventArchive = {},
      },
      observations = { byCampaign = {} },
      operations = { records = {}, order = {}, heads = {}, pending = {}, conflicts = {} },
      confirmationRefs = {}, -- operation IDs only
      migration = nil, -- #386
    },
  },
}
```

- Durable key is only `club:<nonzero club id>`. Transport `name:` scopes are never persisted.
- Absent root → empty defaults. Unsupported/malformed root or guild records are retained read-only; they are not wiped into a fresh authorized default.
- Reads/startup never create per-guild records. `CreateStagedRecord()` is an explicit admitted action.

## Public API (`SF.GuildSupplies`)

| API | Contract |
| --- | --- |
| `:Initialize(db)` | Idempotent root load/validate; no network or guild bootstrap |
| `:GetCurrentContext()` | Native guildKey, actor, rank readiness, handle generation, or waiting reason |
| `:GetCurrentRecord()` | Validated current-guild staged record or nil + reason (no allocate-on-read) |
| `:CreateStagedRecord(editorRankPosition?)` | Explicit create with default editor rank 3 when ≥3 ranks exist; when fewer than 3 ranks, verified GM must pass an existing threshold position |
| `:GetCapabilities()` | `canRead` / `canEdit` / `canRecoverPolicy`, resolved rank name label; Preview as Non-Admin |
| `:NewConfigOperation(kind, target, value)` | Build IDs/actor/timestamp/base revisions from local context |
| `:ValidateConfigOperation(op, context)` | Shape/scope/authority/base checks; no side effects |
| `:ApplyStagedConfigOperation(op, context)` | Staged compare-and-apply; rechecks guild/rank at commit |
| `:NewConfirmationOperation(candidateRef)` / `:ValidateConfirmationOperation` | Local confirmation envelope; no live credit |
| `:GetCurrentCampaignBoundary()` | Validated immutable header or nil + reason |

Mutation statuses: `accepted`, `duplicate`, `pending`, `rejected` with stable reasons (`not_ready`, `wrong_guild`, `unauthorized`, `unsupported_schema`, `stale_base`, `conflict` / `id_conflict`, `full`, …). `accepted` means staged only.

### Config operation kinds / targets

- `set-editor-rank` → target `editorRankPosition`
- `set-bank-tab` → target `bankTab` (explicit `nil` clears; non-nil values must coerce to integral tabs 1–8 — failed conversions reject without clearing)
- `set-requested-item` → target `{ itemId = N }` (add/update/remove share one revision chain; values are canonicalized to `{ itemId, goal, removed=false }` or `{ removed=true }` at prepare/admission so nested extras cannot poison snapshots or exact-duplicate comparison)
- `confirm-candidate` → confirmation envelope (see below)

Caps: **4,096** accepted operations / guild; **128** combined pending+conflict admission bodies / guild (shared budget). Existing-ID retries reuse a slot and do not consume another. Overfull admissions return `full` without partial mutation or eviction. Durable operation snapshots are whitelisted and bounded (depth 6, **1,024** nodes, **49,152** string bytes) so a full confirmation batch of **64** records plus `originalIds` fits; the separate **2 KiB** transport export cap is unchanged. Malformed or oversized input is rejected without partial retention. Retained `records`/`order`/`pending`/`conflicts` entries require map-key/`body.id` identity; `operations.heads` must name accepted bodies for the corresponding target; `confirmationRefs` is a dense unique array of accepted `confirm-candidate` IDs (≤ accepted cap). Inconsistent saved stores stay unavailable without repair-on-read. A malformed `localWriter` nonce on an otherwise supported root is replaced with a fresh 24-hex nonce before new IDs; guild records are preserved and unsupported domain data is never normalized.

### Rank authority (locked)

- 1-based `guildRankOrder` (Guild Master = 1). Default editor threshold = **3**.
- Player-facing labels use `GuildControlGetRankName(position)` (for example `"%s and higher"`).
- Invalid/out-of-range policy → verified Guild Master recovery only.
- Preview as Non-Admin denies privileged actions locally.
- Zero active gossip providers: authority uses a **demand-driven** native snapshot. An unbound observation (including the first after login/reload) starts a temporary `GUILD_ROSTER_UPDATE` wait with a throttled native `GuildRoster` request — nonempty cached rows alone are not freshness. No permanent listeners, discovery, or dummy provider. Identical refreshed rosters may recover; content inequality alone is not freshness. The wait always terminates on event, retarget, or timeout. Missing/uncertain data fails closed. Commit rechecks guild/rank/policy.
- Fresh guilds with fewer than three ranks: `CreateStagedRecord` does not invent a default threshold; verified GM passes an existing 1-based position. Preview as Non-Admin and non-GM callers remain denied.

### Confirmation envelope

`confirm-candidate` carries `schemaVersion, id, guildKey, datasetId, candidateRef, contentFingerprint, campaignId, basePolicyRevision, actorGuid, actorName, timestamp`. `candidateRef` must use exactly one reference form: a single `recordId` **or** a dense `records` manifest (1–64), never both/neither. Manifest rows are canonicalized to `{ id, contentFingerprint }` only at prepare/admission so nested extras cannot poison durable snapshots or exact-duplicate comparison. When `candidateRef.campaignId` is present it must match the envelope `campaignId`. Candidate policy cannot self-authorize. Original IDs are preserved; endorsement is not a live donation credit. Network confirmation exchange is #387/#388.

### Campaign boundary header

Fields: `schemaVersion, campaignId, datasetId, guildKey, parentCampaignId, resetOperationId, createdByGuid, createdByName, startedAt, bankTabAtStart, boundaryVersion=1, boundaryKind ("new-goal"|"legacy-preserved"), contextStatus ("captured"|"empty"|"unavailable"), contextObservedAt, contextRecordCount`. `currentCampaignId` must be nil or a nonempty key whose embedded `campaignId` matches. `new-goal` requires nonempty `resetOperationId == campaignId`, bounded `createdByGuid`/`createdByName`, and finite `startedAt`. `legacy-preserved` may omit historical authors/`startedAt` (do not fabricate them); present values stay type-safe. `contextStatus` `captured`/`empty` require finite `contextObservedAt` and `contextRecordCount` (`empty` ⇒ count 0); `unavailable` may honestly omit observation evidence. `bankTabAtStart` is nil or integral tabs 1–8. `#385` validates/accesses only; bank capture and reset lifecycle are #386.

## Downstream ownership

| Ticket | Owns |
| --- | --- |
| #386 | Migration preview, real campaign reset, Configuration/Logs UI |
| #387 | Decentralized config exchange/merge, conflict UX |
| #388 | Gossip accounting/verification |
| #389 | Live activation, canonical adoption, writer retirement |

## Chat-free policy

No normal game Chat from Guild Supplies. Diagnostics only through enabled `SF.Debug` (`GUILD_SUPPLIES`). Settings status/banner feedback belongs to later UI tickets.

## Evidence

- Production-Lua suite: `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py`
- Gossip idle/repair regressions remain required: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Retail rank/readiness/API checks remain human QA
