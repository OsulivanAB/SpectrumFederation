# Guild Supplies Foundation (Phase 2A + 2B + 3A + 3B + 3C)

Part **2A** (#385) delivers a **dormant, guild-keyed staged foundation**. Part **2B** (#386) adds **fresh-start campaigns**, local eligibility cutoffs, and **visible standalone Settings**. Part **3A** (#387) connects staged configuration to the Guild Gossip provider for authenticated exchange, conflict resolution, and explicit dataset adoption. Part **3B** (#388) adds **staged donation evidence**, automatic verification, guild-owned **character links**, and **ledger gossip** (including editor quantity adjustments). **#411** verifies a donation from one current officer's direct Guild Bank observation, and otherwise keeps the three-witness quorum. Part **3C** (#389) performs **guarded live activation**, publishes the agreed bank cutover boundary, rewires production bank/helper consumers to guild-owned state, and retires legacy profile Consumables writers for the activated guild.

Issue contracts: [#385](https://github.com/OsulivanAB/SpectrumFederation/issues/385), [#386](https://github.com/OsulivanAB/SpectrumFederation/issues/386), [#387](https://github.com/OsulivanAB/SpectrumFederation/issues/387), [#388](https://github.com/OsulivanAB/SpectrumFederation/issues/388), [#389](https://github.com/OsulivanAB/SpectrumFederation/issues/389). Parent roadmap: [#384](https://github.com/OsulivanAB/SpectrumFederation/issues/384) / [#379](https://github.com/OsulivanAB/SpectrumFederation/issues/379). Transport dependency: [#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378).

**Hard release invariant:** Until an authorized editor successfully activates a guild dataset, legacy profile-scoped Consumables remains the live writer. After activation, Guild Supplies is the sole production writer for that guild.

## Change contract (summary)

| Concern | Owner |
| --- | --- |
| Durable guild record / schema validation | `SF.GuildSupplies` (`State`) |
| Live edit authority | Shared officer rank (`SF.GuildOfficer`), rechecked at commit and remote admission |
| Verified current guild/rank capabilities | `Authority` via demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` |
| Operation IDs, typed validation, staged/live local admission | `Operations` (`ApplyStaged*`) |
| Authenticated remote admission / adoption / conflicts | `Admission` (`AdmitRemote*`, adoption APIs) |
| Campaign reset, archives, bank-context capture, eligibility | `Campaigns` |
| Guarded live activation + cutover marker | `Activation` (`ActivateCanonicalDataset`, `InstallRemoteLiveCutover`) |
| Configuration + accounting gossip provider | `Gossip` (`sf.guildsupplies.config`) via Guild Gossip API |
| Donation evidence / officer or three-witness ledger / identity links | `Ledger` |
| Configuration / Logs Settings pages | `UI/Settings/Pages/GuildSupplies*.lua` |
| Live bank observation after activation | `ConsumablesBankLog` → `AdmitDirectObservation` |
| Legacy profile writer isolation | `Consumables.LegacyWritersAllowed` + sync handler gates |
| Gossip transport / discovery | Guild Gossip engine |

## Fresh start (no legacy migration)

- Opening Settings, reading state, or finding an empty local cache **never** auto-creates an authoritative guild dataset. Use explicit `CreateStagedRecord`.
- Fresh staged setup starts with empty campaign/accounting data. Legacy Consumables profiles, totals, history, observations, queues, and transaction registries are **not** imported.
- Unrelated Loot Helper / account data is left alone. Unused `migration` fields stay unused; there is no migration preview or source-selection UI.
- **#389 live cutover:** activation publishes a guild-agreed initial eligibility/cutover context from a fresh Guild Bank transaction-log sample so pre-activation bank-log rows cannot backfill. Client receipt time is never substituted. Compatible peers adopt the authenticated cutover without reopening the bank. Conflicting live markers fail closed.

## Saved schema

Root under the existing account SavedVariables:

```lua
SpectrumFederationDB.guildSupplies = {
  schemaVersion = 1,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<actual club id>"] = {
      schemaVersion = 1,
      activation = "staged" | "active",
      datasetId = "gs1:<guid>:<nonce>:<seq>",
      liveCutover = nil | { -- required when activation == "active"
        schemaVersion = 1,
        datasetId, guildKey, activatedAt, activatedByGuid, activatedByName,
        bankTab, contextStatus ("captured"|"empty"), contextObservedAt, contextRecordCount,
        cutoverMarker = "gsc1:<datasetId>:<activatedAt>:<bankTab>",
        eligibilityBoundary = { baselineEstablished = true, tabEligibleFrom = <contextObservedAt> },
      },
      permission = { editorRankPosition = 3, revisionId = "<datasetId or op id>" }, -- historical metadata; not live auth
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
      identityLinks = { schemaVersion = 1, groups = {}, byGuid = {}, revisionId = nil },
      operations = { records = {}, order = {}, heads = {}, pending = {}, conflicts = {}, openConflicts = {} },
      confirmationRefs = {},
      migration = nil,
      valuations = nil | { -- #397 accepted DBMarket snapshots only; absent on older saves
        schemaVersion = 1,
        nextSeq = 1,
        byTxn = {}, -- [canonicalTxnId] = immutable winner + local seen fingerprints
        pending = {}, -- bounded assignments waiting for the donation to verify
      },
    },
  },
}
```

- Durable key is only `club:<nonzero club id>`. Transport `name:` scopes are never persisted.
- `permission.editorRankPosition` and `set-editor-rank` history remain so existing datasets, revisions, and operation ancestry still validate. They are not a second live authorization source. Current edits use the shared officer rank. A corrupt permission record can still be repaired by the Guild Master without resetting campaigns, donation logs, or accounting. The old editor-rank setting is not migrated.
- Absent root → empty defaults. Unsupported/malformed root or guild records are retained read-only.
- Active records without a valid `liveCutover` fail closed (unavailable), never silently rewritten.

## Donation valuation (#397)

Eligible officers on the exact guild home realm assign one TSM DBMarket snapshot when a live, production-credited donation is verified. That includes a new officer direct credit and a three-witness credit, and an eligible officer who accepts officer-trusted history can price it without opening Logs. Logs open discovers unpriced rows in bounded slices and then queries TSM in bounded batches. Earliest assignment time wins, with the assignment id breaking same-second ties, including when both an alias and its canonical id already hold a candidate. The donation ledger itself is not edited. Values travel as `gs-valuation` records on the existing Guild Supplies gossip provider. The dataset descriptor advertises `valuationCount`, and adoption pins and checks that count before commit. A current editor may relay an offline author's accepted assignment; claimed author fields are not proof. Ordinary members can read the winning total and cannot mint one. Missing TSM leaves the row unpriced. Zero is a real price. Only the accepted snapshot is stored — not a general TSM price cache. Unit copper must stay an exact integer whose product with the donated quantity is strictly below 2^53.

## Public API (`SF.GuildSupplies`) — activation (#389)

| API | Contract |
| --- | --- |
| `:ActivateCanonicalDataset()` | Authorized editor; requires staged dataset, campaign, bank tab, resolved conflicts/adoption, fresh bank sample (`captured` or verified `empty`). Atomic flip to `active` + cutover. Idempotent when already active. |
| `:GetActivationReadiness()` | Non-mutating Settings probe (`canActivate`, bank reasons). |
| `InstallRemoteLiveCutover(record, cutover, guildKey)` | Authenticated catch-up/adoption path; no local bank sample. Divergent markers → `live_activation_conflict`. |
| `:IsLiveActiveForCurrentGuild()` / `IsLiveActive(record)` | Live writer authority checks. |
| `:ShouldUseLegacyConsumablesWriters()` | False once current guild is live-active. |
| `IsEvidenceAfterLiveCutover(record, evidence)` | Pre-cutover approxTxnTime never credits. |

Mutation statuses remain `accepted` / `duplicate` / `pending` / `rejected`. Activation success uses reason `activated` for Settings banner wording.

## Settings UI

| Area | Access |
| --- | --- |
| **Raid Supplies → Configuration** | Initialize, bank tab, New Campaign, items/goals, character links, adjustments, adoption, conflict resolution, **Activate Guild Supplies**. Who can edit follows the shared officer rank. A historical permission repair control appears only when that stored record is corrupt. The category id remains `guildSupplies`. |
| **Raid Supplies → Logs** | Campaign inspection, progress, pending evidence, donation/adjustment history |
| **Personal preferences** | Account-local reminder checkbox |
| **Loot Helper → Consumables / Consumable Logs** | Hidden from navigation after live activation (`page.available`) |

## Donation verification (#411)

Officer eligibility is the established Guild Info threshold at the moment a new local Guild Bank snapshot is admitted: verified `rankOrder <= effectiveThreshold`. One such local observation commits a single canonical credit with `verification = "officer"`, the observer's GUID, and an explicit `verifierGuid` equal to that writer. Remote `gs-evidence` remains a witness. One or two non-officer observations stay pending until a third independent witness or a later local officer snapshot of the same deposit. Rank or policy changes do not revoke an accepted credit and do not upgrade an old report until a newer local snapshot while the character qualifies.

Accepted officer-trusted rows sync through the existing Guild Gossip ledger export. A guildmate who already has the row can serve a late peer after the original officer logs off. Live receivers credit that relay only when the authenticated canonical cutover marker matches. A staged receiver keeps marked accepted history so installing that same marker later classifies it. Competing authenticated markers for one occurrence are retained without last-writer-wins (primary plus one bounded alternate); the established cutover selects the canonical marker. Only a complete officer-history duplicate may attach those markers. A missing or different marker alone is not promoted into live credit. An unverified ledger candidate does not block a later valid officer row for the same occurrence, and that admission clears the matching pending cluster and candidate without dropping unrelated ambiguous or repeated deposits. Catch-up and adoption do not invent a missing `verifierGuid`. Three-witness ledger rows still do not self-credit from gossip. Dataset adoption replays stored witness exports as votes and does not turn one of them into an officer credit. A bare `verification`, `writer`, `rankOrder`, `isAdmin`, or `observedBy` claim is not authority. **v1 limit:** there is no cryptographic proof of which officer saw Blizzard's bank log. An authenticated guild member who sends a complete, eligible officer-provenance row is treated as relaying accepted history.

## Chat-free policy

No normal game Chat from Guild Supplies or rewired live Consumables paths. Diagnostics only through enabled `SF.Debug`. User action feedback uses contextual Settings banners via `FormatMutationFeedback`.

## Evidence

- Production-Lua suite: `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py` (includes 3A–3C and #411 officer-trusted paths)
- Gossip idle/repair regressions: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Settings navigation/layout when pages change: `tests/test_settings_navigation.py`, `tests/test_settings_window_layout.py`
- Retail multi-client smoke steps below; never claim unperformed in-game QA

## Retail multi-client smoke test (human; not claimed by automation)

Automated production-Lua tests do **not** replace Retail QA.

1. Three same-guild Retail characters on this integration build: one GM/editor (A), one editor-rank officer (B), one ordinary member without a Loot Helper profile (C).
2. Optional: enable Debug for transport diagnostics only.
3. On A: Initialize Guild Supplies → New Campaign → set bank tab → add an item/goal.
4. On B and C: confirm the same staged dataset appears via gossip without a raid/session.
5. Resolve any open conflicts / adopt a single staged source before activation.
6. **Activation at a real Guild Bank (A):** open the configured tab, wait for a fresh log sample, Activate Guild Supplies. Confirm Settings banner success and that Raid Consumables pages disappear from navigation.
7. **Catch-up without bank (B/C):** `/reload` or late join; confirm active cutover marker is adopted without reopening the bank.
8. **Conflicting staged roots:** two independently initialized datasets must stay blocked until explicit adoption; never auto-activate on timestamps/counts.
9. **Donation eligibility:** pre-activation bank rows do not credit. After activation, one current officer's direct Guild Bank observation credits an eligible deposit once. Without that observation, three independent witnesses credit it once. A guildmate who already has the accepted officer credit can catch a late member up while the original officer is offline.
10. Deposit assistant / reminders work with **no raid session** and **no Loot Helper profile** after activation.
11. Profile switch/delete, snapshot import, and old-client `CONSUMABLES_*` session traffic must not mutate canonical Guild Supplies or double-credit.
12. New Campaign after activation archives prior goals and starts empty; shared tab/editor policy/cutover identity remain.
13. Disconnect/rejoin, rank demotion, combat/FPS, and normal Loot Helper raid loot behavior remain intact; no game Chat from Guild Supplies paths.
14. **Valuation:** a same-realm officer with TSM prices a new donation; a different-realm officer and an ordinary member do not. Two disconnected officers converge on the earlier assignment after reconnect, in either arrival order. Missing TSM stays unpriced. Archived campaigns and `/reload` keep the winning total. No game Chat and no continuous pricing work while Logs is closed.
