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
| Donation evidence / three-witness ledger / identity links | `Ledger.lua` |
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
12. **3B:** Exactly three independent authenticated witness identities automatically credit one donation. No manual donation approve/reject.
13. **3A:** Independently initialized dataset IDs never silently merge; explicit adoption replaces.

## Lifecycle

```
login → Initialize(empty root) → EnsureGossipProvider
explicit CreateStagedRecord → staged record
New Campaign → empty items + immutable boundary
config ops / gossip / adoption (staged)
sample-only bank observation (editor, no admit) → fresh stamp
ActivateCanonicalDataset (editor + fresh bank sample) → active + liveCutover
  + ClassifyPreActivationAccounting (staged ledger retained, not live credit)
bank observation → AdmitDirectObservation → 3 witnesses → production credit
compatible editor peers InstallRemoteLiveCutover (no bank; editor auth required)
legacy profile writers isolated for that guild
```

## Evidence

- `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py` (3A–3C)
- Gossip idle/repair: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Settings navigation when pages change
- Retail multi-client smoke steps in docs; never claim unperformed in-game QA
