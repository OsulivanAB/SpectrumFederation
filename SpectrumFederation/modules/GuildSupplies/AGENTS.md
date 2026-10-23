# Guild Supplies Phase 2A/2B/3A/3B/3C — Change Contract (#385–#389)

Zip-excluded guidance (`*/AGENTS.md`). Canonical schema/API docs: `docs/development/guild-supplies/`.

## Authority

| Concern | Owner |
| --- | --- |
| Durable guild records | `SF.GuildSupplies` account root (`SpectrumFederationDB.guildSupplies`) |
| Live donation/config writes (after activation) | Guild Supplies canonical dataset (`activation = "active"`) |
| Live donation/config writes (before activation) | Legacy profile-scoped Consumables only |
| Current guild/rank proof | Demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` |
| Preview as Non-Admin | `SF.LootHelperImpersonation` overlay |
| Campaign lifecycle / archives / local eligibility | `Campaigns.lua` via `start-campaign` + config ops |
| Guarded activation + cutover marker | `Activation.lua` |
| Configuration + accounting gossip | `Gossip.lua` provider `sf.guildsupplies.config` |
| Local-action commits | `ApplyStaged*` + `_AuthorizeCommit` (local player only) |
| Authenticated remote admission | `AdmitRemote*` — transport sender + verified guild/rank policy |
| Dataset adoption | Explicit authorized editor confirmation; replace, never merge |
| Donation evidence / officer or three-witness ledger / identity links | `Ledger.lua` |
| Donation DBMarket valuation (#397) | `Valuation.lua` on the guild record; gossip kind `gs-valuation` |
| Deposit matching helpers | Reuse `SF.ConsumablesObservation` MatchScore / BuildEvidence / ListEligibleEvidenceFromSnapshot |

## Guarantees

1. Reads/startup never create per-guild records; `CreateStagedRecord` is explicit. No legacy Consumables import.
2. Durable key is only `club:<actual id>`; `name:` transport scopes are rejected.
3. Default editor threshold is logical rank position 3; labels use actual rank names.
4. Invalid/out-of-range policy permits verified Guild Master recovery only.
5. Compare-and-apply statuses: accepted / duplicate / pending / rejected.
6. Missing data fails closed; commit/admission rechecks guild/rank/policy.
7. Chat-free: enabled `SF.Debug` only. Settings banners use `FormatMutationFeedback`.
8. **3C:** Any verified authorized editor (not GM-only) may activate. Activation requires a fresh bank sample on the activating client, publishes a durable cutover marker, and is idempotent.
9. **3C:** Pre-activation bank rows / staged pending evidence / staged accepted ledger rows never become live credit (`gsProductionCredit`). Compatible peers adopt cutover without reopening the bank. Authenticated divergent live markers fail closed on production writers.
10. **3C:** After activation, `ShouldUseLegacyConsumablesWriters()` is false; profile ApplyOp/CommitEvents/MergeSnapshot and legacy sync handlers cannot mutate production accounting for that guild.
11. **3C:** Staged sample-only bank observation lets an authorized editor stamp the configured GS tab without admitting donations or requiring a legacy profile. Remote live cutover install requires verified editor authority.
12. **3B / #411:** A current officer's new local completed Guild Bank snapshot credits one eligible donation with durable `verification = "officer"` provenance. Remote `gs-evidence` stays a witness and can still complete the three-witness quorum. Otherwise exactly three independent authenticated witness identities credit it with `verification = "witnesses"`. Officer rank is the established Guild Info threshold at admission time (`rankOrder <= effectiveThreshold`), not a payload claim. Rank or threshold changes do not upgrade an old witness report; a newer local snapshot while the character qualifies does. No manual donation approve/reject.
13. **#411 catch-up:** An accepted officer-trusted row propagates through ordinary `gs-ledger-event` gossip, including A → B → C while A is offline. The receiver accepts it only from an authenticated same-guild sender, with matching dataset/campaign/occurrence, an explicit `verifierGuid` equal to `writer`, and, when the receiver is live, the authenticated canonical cutover marker. A matching unverified candidate does not block that later row. Admission reconciles the matching pending cluster and candidates and leaves ambiguous or distinct deposits alone. A staged peer may retain a marked accepted row before cutover is installed; installing that same marker classifies it. If a staged peer retained the same occurrence unmarked or with competing authenticated markers, a later complete officer-history marked duplicate retains up to one bounded alternate without last-writer-wins; the established cutover selects the canonical marker and credits exactly once (marker arrival before or after install). Witness-only or incomplete officer duplicates cannot attach cutover provenance. Missing or divergent markers alone are not promoted into live credit. Missing verifier provenance is not synthesized on catch-up or adoption. Three-witness ledger rows stay unverified candidates until local quorum. Dataset adoption replays stored `gs-evidence` as witness votes only; it does not officer-credit that replay. The accepted ledger row carries the credit. **v1 limit:** addon messages are not cryptographic proof that the named officer saw Blizzard's bank log. A guild member who can send a well-formed officer-provenance row is indistinguishable from a peer relaying accepted history. Do not treat a bare `verification` / `writer` / `rankOrder` / `isAdmin` claim as authority, and do not require the original officer to stay online.
14. **3A:** Independently initialized dataset IDs never silently merge; explicit adoption replaces.
15. **#397:** One effective DBMarket snapshot per canonical production donation. Earliest `(assignedAt, assignmentId)` wins, including when both an alias and its canonical id already have pending or accepted candidates. Local mint requires current officer edit plus an exact guild-home realm match, and runs for a new officer direct credit and for a three-witness credit. Ingress accepts an immutable assignment only from a current editor on the authenticated transport sender; claimed actor fields are not authority. Accepting officer-trusted history reconciles valuations that arrived first and, on an eligible same-realm officer, attempts a price without opening Logs. Ordinary members cannot mint. Missing TSM stays unpriced, including zero as a real price. The snapshot is the only TSM value copied into SavedVariables. Adoption advertises and pins the valuation count with the dataset descriptor. Publishing or removing a winner updates that advertised count in place, without a full export rebuild. A same-dataset staged peer keeps an authorized matching assignment pending until the installed cutover classifies that donation; it is not an accepted price or an export before then, and a definitive miss after classification is discarded. Aliasing transaction ids before that donation exists, or while its credit is still unresolved, keeps the earliest valid pending candidate on the canonical id and still does not export it. An unchanged valuation store is not fully rescanned on every read; a replaced or malformed store still fails closed. Export maintenance reuses the tracked valuation manifest until the winner set or dataset changes. Valuation cleanup on a temporary adoption record does not edit the active dataset's exports. An unexpected TSM adapter exception is debug-logged and leaves the row unpriced.

## Lifecycle

```
login → Initialize(empty root) → EnsureGossipProvider
explicit CreateStagedRecord → staged record
New Campaign → empty items + immutable boundary
config ops / gossip / adoption (staged)
sample-only bank observation (editor, no admit) → fresh stamp
ActivateCanonicalDataset (editor + fresh bank sample) → active + liveCutover
  + ClassifyPreActivationAccounting (staged ledger retained, not live credit)
local bank snapshot → AdmitDirectObservation → officer direct credit OR 3 witnesses → production credit
remote gs-evidence → witness only (quorum still completes)
accepted officer row → gs-ledger-event catch-up (explicit verifierGuid; live marker required; original officer may be offline)
compatible editor peers InstallRemoteLiveCutover (no bank; editor auth required)
legacy profile writers isolated for that guild
```

## Evidence

- `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py` (3A–3C)
- Gossip idle/repair: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Settings navigation when pages change
- Retail multi-client smoke steps in docs; never claim unperformed in-game QA
