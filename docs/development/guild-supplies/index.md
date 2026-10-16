# Guild Supplies Foundation (Phase 2A + 2B)

Part **2A** (#385) delivers a **dormant, guild-keyed staged foundation**. Part **2B** (#386) adds **fresh-start campaigns**, local eligibility cutoffs, and **visible standalone Settings** on the integration branch. Neither phase migrates legacy Consumables data, registers a gossip provider, or activates live guild-wide bank writes.

Issue contracts: [#385](https://github.com/OsulivanAB/SpectrumFederation/issues/385), [#386](https://github.com/OsulivanAB/SpectrumFederation/issues/386). Parent roadmap: [#384](https://github.com/OsulivanAB/SpectrumFederation/issues/384). Transport dependency: [#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378).

**Hard release invariant:** Legacy profile-scoped Consumables remains the only live authoritative writer until [#389](https://github.com/OsulivanAB/SpectrumFederation/issues/389).

## Change contract (summary)

| Concern | Owner |
| --- | --- |
| Durable staged guild record / schema validation | `SF.GuildSupplies` (`State`) |
| Verified current guild/rank capabilities | `Authority` via demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` |
| Operation IDs, typed validation, staged admission | `Operations` |
| Campaign reset, archives, bank-context capture, eligibility | `Campaigns` |
| Configuration / Logs Settings pages | `UI/Settings/Pages/GuildSupplies*.lua` |
| Live donation ledger / bank verification | Legacy Consumables (unchanged) |
| Gossip transport / discovery | Guild Gossip (no Guild Supplies provider yet) |

## Fresh start (no legacy migration)

- Opening Settings, reading state, or finding an empty local cache **never** auto-creates an authoritative guild dataset. Use explicit `CreateStagedRecord`.
- Fresh staged setup starts with empty campaign/accounting data. Legacy Consumables profiles, totals, history, observations, queues, and transaction registries are **not** imported.
- Unrelated Loot Helper / account data is left alone. Unused `migration` fields stay unused; there is no migration preview or source-selection UI.
- **#389 live-cutover handoff:** activation must publish a guild-agreed initial eligibility/cutover context so pre-activation bank-log rows, legacy queues, or deposits observed before activation cannot backfill the hard-reset system. Client receipt time or a development-preview timestamp must not substitute for that agreed cutover. Canonical bootstrap/adoption between independently prepared fresh roots also remains #389.

## Saved schema

Root under the existing account SavedVariables:

```lua
SpectrumFederationDB.guildSupplies = {
  schemaVersion = 1,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<actual club id>"] = {
      schemaVersion = 1,
      activation = "staged", -- never "active" until #389
      datasetId = "gs1:<guid>:<nonce>:<seq>",
      permission = { editorRankPosition = 3, revisionId = "<datasetId or op id>" },
      currentCampaignId = "<campaignId or nil>",
      campaigns = { -- [campaignId] = immutable boundary header },
      campaignArchives = { -- [campaignId] = frozen requestedItems + generation },
      campaignContext = { -- [campaignId] = bounded bank anchors (not gossip envelopes) },
      accounting = {
        _consumables = { guild = { guid, name, realm }, bankTab, requestedItems, eligibility, txnRegistry, ... },
        _consumableEvents = {},
        _consumableEventArchive = {},
      },
      observations = { byCampaign = {} },
      operations = { records = {}, order = {}, heads = {}, pending = {}, conflicts = {} },
      confirmationRefs = {},
      migration = nil, -- unused; hard reset replaces import workflows
    },
  },
}
```

- Durable key is only `club:<nonzero club id>`. Transport `name:` scopes are never persisted.
- Absent root → empty defaults. Unsupported/malformed root or guild records are retained read-only.
- Campaign headers beyond `MAX_CAMPAIGNS` (64) fail closed. Malformed **archived** headers are retained but omitted from inspectable lists.

## Ownership within a guild record

| Shared across campaigns | Campaign-owned |
| --- | --- |
| Guild identity (`club:` key / accounting guild guid) | Requested items / goals |
| Configured bank tab | Immutable boundary header + context status |
| Editor-rank policy | Progress projections for that generation |
| Personal reminder prefs (account-local Settings) | Archived configuration snapshots |
| Cross-campaign `txnRegistry` deduplication | Observation scopes under `byCampaign` |

## Public API (`SF.GuildSupplies`)

| API | Contract |
| --- | --- |
| `:Initialize(db)` | Idempotent root load/validate; no network or guild bootstrap |
| `:GetCurrentContext()` | Native guildKey, actor, rank readiness, handle generation, or waiting reason |
| `:GetCurrentRecord()` | Validated current-guild staged record or nil + reason (no allocate-on-read) |
| `:CreateStagedRecord(editorRankPosition?)` | Explicit create with default editor rank 3 when ≥3 ranks exist |
| `:GetCapabilities()` | `canRead` / `canEdit` / `canRecoverPolicy`; Preview as Non-Admin |
| `:NewConfigOperation` / `:ValidateConfigOperation` / `:ApplyStagedConfigOperation` | Config kinds below |
| `:NewCampaignOperation` / `:ValidateCampaignOperation` / `:ApplyStagedCampaignOperation` | Confirmed New Campaign lifecycle |
| `:GetCurrentCampaignBoundary()` | Validated immutable current header or nil + reason |
| `:ListInspectableCampaigns()` | Validated current/archived headers only (copies/metadata) |
| `:GetCampaignRequestedItems(campaignId)` | Defensive copy of live or archived items |
| `:ProjectCampaignProgress(campaignId)` | Bounded generation-scoped totals |
| `CaptureBankContext(bankTab)` | Non-crediting context: `captured` / `empty` / `unavailable` |
| `FormatMutationFeedback(status, reason)` | Settings banner text + severity for accepted/duplicate/pending/rejected |

Mutation statuses: `accepted`, `duplicate`, `pending`, `rejected`. `accepted` means **staged admission only**. UI must not treat a nonempty reason string as success or show “Saved” for rejection.

### Config operation kinds / targets

- `set-editor-rank` → target `editorRankPosition`
- `set-bank-tab` → target `bankTab` (shared; tab changes establish eligibility cutoffs after baseline)
- `set-requested-item` → target `{ itemId = N }` (**requires current campaign**; add/re-add sets item cutoffs; goal edits preserve them)
- `confirm-candidate` → confirmation envelope (unchanged from 2A)
- `start-campaign` → target `campaign` (campaign id == operation id == `resetOperationId`)

Caps: **4,096** accepted operations / guild; **128** pending+conflict bodies; **64** campaigns; **16** bank-context anchors / campaign. Capacity exhaustion returns `full` without partial mutation. Durable snapshots stay whitelisted/bounded; the **2 KiB** transport export cap is unchanged.

### Campaign lifecycle

1. Editors confirm **New Campaign**.
2. Admission reallocates an operation id, rechecks guild/rank/policy/base campaign/revisions after the dialog, and captures bank context without verification.
3. On success (atomic): archive prior campaign’s requested items (if any), clear the live item list, bump generation, establish eligibility baseline, install the immutable `new-goal` boundary, select `currentCampaignId`, retain the operation under `campaign:lifecycle`.
4. Failure, stale context, or capacity exhaustion leaves the previous campaign/configuration/accounting intact.
5. Exact retry/reload of the same operation id is `duplicate`. A distinct subsequent confirmed reset receives a new id.
6. Logs can inspect archived configuration/history; viewing never mutates a historical campaign.

### Campaign boundary header

Fields: `schemaVersion, campaignId, datasetId, guildKey, parentCampaignId, resetOperationId, createdByGuid, createdByName, startedAt, bankTabAtStart, boundaryVersion=1, boundaryKind ("new-goal"|"legacy-preserved"), contextStatus ("captured"|"empty"|"unavailable"), contextObservedAt, contextRecordCount`.

- `new-goal` requires nonempty `resetOperationId == campaignId`, bounded authors, and finite `startedAt`.
- `contextStatus` `captured`/`empty` require finite observation metadata (`empty` ⇒ count 0); `unavailable` may honestly omit evidence (including closed bank / missing APIs).
- Delayed clients must use the original shared boundary, never local receipt time, as the campaign start.

### Local eligibility

- After a campaign baseline exists, **tab changes** set `eligibility.tabEligibleFrom`.
- **Item add/re-add** sets `eligibility.items[itemId]`.
- **Ordinary goal edits** and removals preserve existing cutoffs/history.
- Cross-campaign `txnRegistry` identities are retained so empty progress does not forget prior canonical transactions.
- Uncertain / overlapping bank evidence stays pending for #388; time eligibility alone never proves uniqueness.

### Rank authority (locked)

Unchanged from 2A: default editor threshold 3; actual rank-name labels; GM recovery for invalid policy; Preview as Non-Admin denies privileged actions; demand-driven roster authority with no Guild Supplies provider.

## Settings UI (visible on the integration branch)

| Area | Access |
| --- | --- |
| **Guild Supplies → Configuration** | Eligible editors / GM recovery: initialize, bank tab, New Campaign, items/goals, staged status |
| **Guild Supplies → Logs** | Verified same-guild members: inspect current/archived campaigns, goals, progress |
| **Personal preferences** | Account-local reminder checkbox; available to ordinary members |

Pages must show staged/inactive wording. They do not claim live bank-helper or gossip sync has switched. Guild Supplies access does not depend on Loot Helper profile/admin/session.

## Downstream ownership

| Ticket | Owns |
| --- | --- |
| #387 | Decentralized config exchange/merge, conflict UX |
| #388 | Gossip accounting/verification / historical reconciliation |
| #389 | Live activation, agreed cutover eligibility, canonical adoption, legacy-writer retirement |

## Chat-free policy

No normal game Chat from Guild Supplies. Diagnostics only through enabled `SF.Debug` (`GUILD_SUPPLIES`). User action feedback uses contextual Settings banners via `FormatMutationFeedback`.

## Evidence

- Production-Lua suite: `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py`
- Gossip idle/repair regressions: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Settings navigation/layout when pages change: `tests/test_settings_navigation.py`, `tests/test_settings_window_layout.py`
- Retail rank/readiness/bank-context checks remain human QA
