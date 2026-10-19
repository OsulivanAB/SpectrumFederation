# Guild Supplies Foundation (Phase 2A + 2B + 3A + 3B)

Part **2A** (#385) delivers a **dormant, guild-keyed staged foundation**. Part **2B** (#386) adds **fresh-start campaigns**, local eligibility cutoffs, and **visible standalone Settings**. Part **3A** (#387) connects staged configuration to the Guild Gossip provider for authenticated exchange, conflict resolution, and explicit dataset adoption. Part **3B** (#388) adds **staged donation evidence**, automatic **three-witness** verification, guild-owned **character links**, and **ledger gossip** (including editor quantity adjustments). None of these phases migrate legacy Consumables data or activate live guild-wide bank writes.

Issue contracts: [#385](https://github.com/OsulivanAB/SpectrumFederation/issues/385), [#386](https://github.com/OsulivanAB/SpectrumFederation/issues/386), [#387](https://github.com/OsulivanAB/SpectrumFederation/issues/387), [#388](https://github.com/OsulivanAB/SpectrumFederation/issues/388). Parent roadmap: [#384](https://github.com/OsulivanAB/SpectrumFederation/issues/384) / [#379](https://github.com/OsulivanAB/SpectrumFederation/issues/379). Transport dependency: [#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378).

**Hard release invariant:** Legacy profile-scoped Consumables remains the only live authoritative writer until [#389](https://github.com/OsulivanAB/SpectrumFederation/issues/389).

## Change contract (summary)

| Concern | Owner |
| --- | --- |
| Durable staged guild record / schema validation | `SF.GuildSupplies` (`State`) |
| Verified current guild/rank capabilities | `Authority` via demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` |
| Operation IDs, typed validation, staged local admission | `Operations` (`ApplyStaged*`) |
| Authenticated remote admission / adoption / conflicts | `Admission` (`AdmitRemote*`, adoption APIs) |
| Campaign reset, archives, bank-context capture, eligibility | `Campaigns` |
| Staged configuration + accounting gossip provider | `Gossip` (`sf.guildsupplies.config`) via Guild Gossip API |
| Donation evidence / three-witness ledger / identity links | `Ledger` (staged only; #388) |
| Configuration / Logs Settings pages | `UI/Settings/Pages/GuildSupplies*.lua` |
| Live donation ledger / bank verification | Legacy Consumables (unchanged until #389) |
| Gossip transport / discovery | Guild Gossip engine |

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
      observations = { byCampaign = {} }, -- pending evidence clusters per campaign (#388)
      identityLinks = { schemaVersion = 1, groups = {}, byGuid = {}, revisionId = nil }, -- #388
      operations = { records = {}, order = {}, heads = {}, pending = {}, conflicts = {}, openConflicts = {} },
      confirmationRefs = {},
      migration = nil, -- unused; hard reset replaces import workflows
    },
  },
}
```

- Durable key is only `club:<nonzero club id>`. Transport `name:` scopes are never persisted.
- Absent root → empty defaults. Unsupported/malformed root or guild records are retained read-only.
- Campaign headers beyond `MAX_CAMPAIGNS` (64) fail closed. Malformed **archived** headers are retained but omitted from inspectable lists.
- `operations.openConflicts` holds same-target divergent candidate IDs until an authenticated resolution clears them (#387).

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
| `:Initialize(db)` | Idempotent root load/validate; registers staged config gossip provider |
| `:GetCurrentContext()` | Native guildKey, actor, rank readiness, handle generation, or waiting reason |
| `:GetCurrentRecord()` | Validated current-guild staged record or nil + reason (no allocate-on-read) |
| `:CreateStagedRecord(editorRankPosition?)` | Explicit create with default editor rank 3 when ≥3 ranks exist |
| `:GetCapabilities()` | `canRead` / `canEdit` / `canRecoverPolicy`; Preview as Non-Admin |
| `:NewConfigOperation` / `:ValidateConfigOperation` / `:ApplyStagedConfigOperation` | Local-action config kinds (local player only) |
| `:AdmitRemoteOperation(op, ctx)` | Authenticated remote admission; transport sender + verified policy |
| `:NewCampaignOperation` / `:ValidateCampaignOperation` / `:ApplyStagedCampaignOperation` | Confirmed New Campaign lifecycle |
| `:NewConfirmationOperation` / `:ApplyStagedConfirmationOperation` | Historical candidate confirmation |
| `:NewConflictResolutionOperation` / `:ApplyStagedConflictResolution` | Explicit same-target / campaign conflict choice |
| `:BeginDatasetAdoption` / `:CommitDatasetAdoption` / `:CancelDatasetAdoption` | Explicit replace-only staged dataset adoption |
| `:ListOpenConflicts` / `:ListPeerDatasets` / `:GetDatasetMismatchState` | Conflict + adoption Settings helpers |
| `:GetCurrentCampaignBoundary()` | Validated immutable current header or nil + reason |
| `:ListInspectableCampaigns()` | Validated current/archived headers only (copies/metadata) |
| `:GetCampaignRequestedItems(campaignId)` | Defensive copy of live or archived items |
| `:ProjectCampaignProgress(campaignId)` | Bounded generation-scoped totals (current + archive ledger; attributed adjustments) |
| `:ListCampaignHistory(campaignId, limit, offset)` | Bounded read-only donation/adjustment history for Logs |
| `:AdmitDirectObservation(evidence, ctx)` | Authenticated sender GUID votes once; auto-credits at 3 independent witnesses |
| `:AdmitLedgerEvent(event, ctx)` | Catch-up admission with occurrence-aware donation dedupe |
| `:ListPendingEvidence(campaignId)` | Read-only pending/ambiguous deposit clusters |
| `:NewLinkCharactersOperation` / `:NewUnlinkCharacterOperation` / `:NewAdjustmentOperation` | Editor link/adjust prepare APIs |
| `IsBankContextSampleReady(bankTab)` | Read-only readiness via existing bank-log evidence / test probe |
| `CaptureBankContext(bankTab)` | Non-crediting context: `captured` / `empty` only when ready; otherwise `unavailable` |
| `FormatMutationFeedback(status, reason)` / `FormatReasonText(reason)` | Localized Settings banner text + severity |

Mutation statuses: `accepted`, `duplicate`, `pending`, `rejected`. `accepted` means **staged admission only**. UI must not treat a nonempty reason string as success or show “Saved” for rejection.

### Config operation kinds / targets

- `set-editor-rank` → target `editorRankPosition`
- `set-bank-tab` → target `bankTab` (shared; tab changes establish eligibility cutoffs after baseline)
- `set-requested-item` → target `{ itemId = N }` (**requires current campaign**; add/re-add sets item cutoffs; goal edits preserve them)
- `confirm-candidate` → confirmation envelope
- `start-campaign` → target `campaign` (campaign id == operation id == `resetOperationId`)
- `resolve-conflict` → target = conflicted target key; value references competing op IDs + exact fingerprints
- `link-characters` / `unlink-characters` → target `identity-links` (#388)
- `adjust-quantity` → target `{ itemId }` (#388; never verifies deposits)

Caps: **4,096** accepted operations / guild; **128** pending+conflict bodies; **64** campaigns; **16** bank-context anchors / campaign; **32** open target conflicts; **128** pending evidence clusters; **64** identity-link groups. Capacity exhaustion returns `full` without partial mutation. Durable snapshots stay whitelisted/bounded; the **2 KiB** transport export cap is unchanged.

### Staged configuration gossip (#387) + accounting (#388)

Provider id: `sf.guildsupplies.config`.

- Registers through `SF.GuildGossip:Register` / `RegisterProvider` on `Initialize`.
- Exports compact `dataset-desc`, accepted `gs-op` envelopes (with original campaign boundaries), campaign headers, archives, and staged `gs-ledger-event` bodies.
- Also admits `gs-evidence` records: only the authenticated transport sender GUID counts as a witness.
- Discovery capabilities stay compact (`datasetId`, schema, staged flags) — no detailed history in guild discovery.
- `ValidateAndApply` authenticates `ctx.sender` via `GG.GetGuildMember`; payload author/rank fields are not authentication.
- Ordinary members may receive an authenticated editor's dataset (replication) without gaining edit rights.
- Independently initialized dataset IDs never silently merge. Authorized editors adopt a peer dataset via confirmed **replace** (cancel / incomplete / stale leave prior state; adoption epoch invalidates old-dataset traffic).
- Compatible independent edits merge; same-target and concurrent New Campaign conflicts preserve candidates until explicit resolution.
- Untrusted relays remain pending until an authenticated editor confirms exact content.
- Remote replay preserves original eligibility timestamps/boundaries; receipt time is never substituted.
- Local durable writes call `GG.NotifyProviderChanged`.

### Donation evidence and ledger (#388)

- **Fixed quorum: 3** independent authenticated Guild Bank observers (character GUIDs after guild-owned link collapse). No admin-trust shortcut or manual donation review.
- Matching reuses `ConsumablesObservation` (relative-time / neighbor / occurrence). Core signature alone does not prove uniqueness.
- Competing txn IDs for the same occurrence alias without a second credit. Ambiguous evidence stays pending.
- Character links are guild/dataset-scoped editor ops; changing links does not rewrite accepted donations.
- Editor quantity adjustments are separate from verification; nonnegative floors are enforced against the accepted projection at commit.
- Honest limitation: "independent" means distinct authenticated GUIDs after known links — not cryptographically proven distinct humans/accounts.
- Staged only: live bank observer / helper / production Settings writers remain legacy until #389.

### Campaign lifecycle

1. Editors confirm **New Campaign**.
2. Admission reallocates an operation id, rechecks guild/rank/policy/base campaign/revisions after the dialog, and captures bank context without verification.
3. On success (atomic): archive prior campaign’s requested items (if any), clear the live item list, bump generation, establish eligibility baseline, install the immutable `new-goal` boundary, select `currentCampaignId`, retain the operation under `campaign:lifecycle`.
4. Failure, stale context, or capacity exhaustion leaves the previous campaign/configuration/accounting intact.
5. Exact retry/reload of the same operation id is `duplicate`. A distinct subsequent confirmed reset receives a new id.
6. Logs can inspect archived configuration/history; viewing never mutates a historical campaign.
7. Remote campaign apply installs the **original** boundary from the gossip envelope; it does not recapture the receiver's bank.

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

Unchanged from 2A: default editor threshold 3; actual rank-name labels; GM recovery for invalid policy; Preview as Non-Admin denies privileged actions; demand-driven roster authority.

## Settings UI (visible on the integration branch)

| Area | Access |
| --- | --- |
| **Guild Supplies → Configuration** | Eligible editors / GM recovery: initialize, editor rank, bank tab, New Campaign, items/goals, character links, quantity adjustments, staged dataset adoption, conflict resolution, staged status |
| **Guild Supplies → Logs** | Verified same-guild members: inspect current/archived campaigns, goals, progress, pending evidence, and bounded donation/adjustment history |
| **Personal preferences** | Account-local reminder checkbox; available to ordinary members |

Pages must show staged/inactive wording. They do not claim live bank-helper authority has switched. Guild Supplies access does not depend on Loot Helper profile/admin/session.

## Downstream ownership

| Ticket | Owns |
| --- | --- |
| #388 | Staged donation evidence, three-witness ledger, identity links, adjustment gossip (this document) |
| #389 | Live activation, agreed cutover eligibility, canonical adoption, legacy-writer retirement (including removal of legacy donation-review consumers) |

## Chat-free policy

No normal game Chat from Guild Supplies. Diagnostics only through enabled `SF.Debug` (`GUILD_SUPPLIES`). User action feedback uses contextual Settings banners via `FormatMutationFeedback`.

## Evidence

- Production-Lua suite: `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py` (includes 3A provider/admission/adoption paths)
- Gossip idle/repair regressions: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Settings navigation/layout when pages change: `tests/test_settings_navigation.py`, `tests/test_settings_window_layout.py`
- Retail multi-client smoke steps below; never claim unperformed in-game QA

## Retail multi-client smoke test (human; not claimed by automation)

Automated production-Lua tests do **not** replace Retail QA.

1. Three same-guild Retail characters on this integration build: one GM/editor (A), one editor-rank officer (B), one ordinary member without a Loot Helper profile (C).
2. Optional: enable Debug for transport diagnostics only.
3. On A: Initialize Guild Supplies → New Campaign → set bank tab → add an item/goal.
4. On B and C: confirm the same staged dataset appears via gossip without a raid/session. C must see configuration but must not gain edit controls.
5. On A and B: independently edit different fields; confirm convergence. Edit the same field from divergent bases; confirm Configuration shows a conflict and an authorized choice resolves both clients to the same result regardless of delivery order.
6. On A and B: independently Initialize if needed to produce different dataset IDs; confirm mismatch stays blocked until an authorized editor adopts with confirmation; cancel and incomplete transfer leave the prior dataset; after successful adoption, delayed old-dataset traffic does not restore it.
7. Disconnect/rejoin, `/reload`, rank demotion, and guild switch: confirm pending/rejected behavior stays bounded and idle, with no game Chat output.

### Additional #388 Retail smoke (human; not claimed by automation)

8. Three same-guild observers with the Guild Bank open see the same eligible deposit: confirm automatic staged credit at the third independent witness with no approval UI and no Chat.
9. Link two alt GUIDs as an editor: confirm those alts count as one witness; unlinked third party still required for quorum.
10. Two editors attempt concurrent negative adjustments that would overdraw: confirm totals never go negative and incompatible candidates stay pending.
11. Confirm Logs shows pending evidence read-only and Configuration adjustments/links use contextual banners only.
