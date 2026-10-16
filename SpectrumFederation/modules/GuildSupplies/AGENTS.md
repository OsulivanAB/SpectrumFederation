# Guild Supplies Phase 2A/2B — Change Contract (#385 / #386)

Zip-excluded guidance (`*/AGENTS.md`). Canonical schema/API docs: `docs/development/guild-supplies/`.

## Authority

| Concern | Owner |
| --- | --- |
| Staged durable guild records | `SF.GuildSupplies` account root (`SpectrumFederationDB.guildSupplies`) |
| Live donation/config writes | Legacy profile-scoped Consumables only |
| Current guild/rank proof | Demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` (not idle gossip cache) |
| Preview as Non-Admin | `SF.LootHelperImpersonation` overlay |
| Campaign lifecycle / archives / local eligibility | `Campaigns.lua` via staged `start-campaign` + config ops |

## Guarantees

1. Reads/startup never create per-guild records; `CreateStagedRecord` is explicit. No legacy Consumables import.
2. Durable key is only `club:<actual id>`; `name:` transport scopes are rejected.
3. Default editor threshold is logical rank position 3; labels use actual rank names.
4. Invalid/out-of-range policy permits verified Guild Master recovery only.
5. Staged compare-and-apply statuses: accepted / duplicate / pending / rejected.
6. Zero active gossip providers still support demand-driven authority; missing data fails closed; commit rechecks guild/rank/policy.
7. Accepted SavedVariables operation bodies must pass kind-specific historical shape validation (including `start-campaign`) before a guild record is exposed as usable.
8. `operations.order` must be a bounded dense array with keys exactly `1..n`.
9. Current `permission.revisionId` / `editorRankPosition` must match bootstrap `datasetId` or accepted `set-editor-rank` head.
10. Chat-free: enabled `SF.Debug` only. Settings banners use `FormatMutationFeedback`. No Guild Supplies provider registration in 2A/2B.
11. New Campaign is authorized, confirmed, atomic, and idempotent; `_StoreCampaignBoundaryForTests` is not the production mutation API.
12. Tab/item add/re-add establish eligibility cutoffs after baseline; goal edits preserve them. Capacity failure leaves prior state intact.
13. Visible Settings on the integration branch do not authorize live bank/helper rewiring (#389).

## Dependencies / invalidation

- Actual club ID, local GUID/name, rank order/names, accepted permission revision, current campaign id / campaign lifecycle head.
- Guild key change bumps handle generation; prepared ops cannot commit across it.
- Unsupported/malformed saved roots/records are retained unavailable, never normalized into defaults.
- Malformed archived campaign headers are retained but omitted from `ListInspectableCampaigns`.

## Lifecycle

```
login → Initialize(empty root)
explicit CreateStagedRecord (verified editor) → staged record
New Campaign (confirmed) → empty items + immutable boundary + archive prior
config ops (bank tab / items / rank) → dormant staged only
Settings Configuration/Logs → banners; no Chat
no provider → gossip adapter remains idle
#389 → agreed live cutover eligibility + writer retirement
```

## Evidence

- `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py`
- Gossip idle/repair: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Settings navigation/layout when pages change
- Retail rank/readiness/bank-context remains human QA
