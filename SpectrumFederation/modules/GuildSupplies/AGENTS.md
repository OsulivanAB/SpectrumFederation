# Guild Supplies Phase 2A/2B/3A — Change Contract (#385 / #386 / #387)

Zip-excluded guidance (`*/AGENTS.md`). Canonical schema/API docs: `docs/development/guild-supplies/`.

## Authority

| Concern | Owner |
| --- | --- |
| Staged durable guild records | `SF.GuildSupplies` account root (`SpectrumFederationDB.guildSupplies`) |
| Live donation/config writes | Legacy profile-scoped Consumables only (until #389) |
| Current guild/rank proof | Demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` |
| Preview as Non-Admin | `SF.LootHelperImpersonation` overlay |
| Campaign lifecycle / archives / local eligibility | `Campaigns.lua` via staged `start-campaign` + config ops |
| Staged configuration gossip | `Gossip.lua` provider `sf.guildsupplies.config` via Guild Gossip API |
| Local-action commits | `ApplyStaged*` + `_AuthorizeCommit` (local player only) |
| Authenticated remote admission | `AdmitRemote*` — transport sender + verified guild/rank policy; not local-action APIs |
| Staged dataset adoption | Explicit authorized editor confirmation; replace, never merge |

## Guarantees

1. Reads/startup never create per-guild records; `CreateStagedRecord` is explicit. No legacy Consumables import.
2. Durable key is only `club:<actual id>`; `name:` transport scopes are rejected.
3. Default editor threshold is logical rank position 3; labels use actual rank names.
4. Invalid/out-of-range policy permits verified Guild Master recovery only.
5. Staged compare-and-apply statuses: accepted / duplicate / pending / rejected.
6. Missing data fails closed; commit/admission rechecks guild/rank/policy.
7. Accepted SavedVariables operation bodies must pass kind-specific historical shape validation before a guild record is exposed as usable.
8. `operations.order` must be a bounded dense array with keys exactly `1..n`.
9. Current `permission.revisionId` / `editorRankPosition` must match bootstrap `datasetId` or accepted `set-editor-rank` head.
10. Chat-free: enabled `SF.Debug` only. Settings banners use `FormatMutationFeedback`.
11. New Campaign is authorized, confirmed, atomic, and idempotent; `_StoreCampaignBoundaryForTests` is not the production mutation API.
12. Tab/item add/re-add establish eligibility cutoffs after baseline; goal edits preserve them. Capacity failure leaves prior state intact.
13. Visible Settings on the integration branch do not authorize live bank/helper rewiring (#389).
14. **3A:** Independently initialized dataset IDs never silently merge. Ordinary members may receive an authenticated editor's staged dataset without gaining edit rights. Explicit adoption replaces the local staged dataset after validated transfer; cancel/incomplete/stale leaves prior state intact and invalidates old-dataset runtime work.
15. **3A:** Compatible independent edits merge; same-target / concurrent campaign conflicts preserve candidates until an authenticated editor resolves them. Untrusted relays stay pending until an authenticated editor confirms exact content.
16. **3A:** Remote replay preserves original campaign/item/tab eligibility boundaries; receipt time must not substitute for originals.

## Dependencies / invalidation

- Actual club ID, local GUID/name, rank order/names, accepted permission revision, current campaign id / campaign lifecycle head, dataset id / adoption epoch.
- Guild key change bumps handle generation; prepared ops cannot commit across it.
- Dataset replacement bumps the adoption epoch so delayed old-dataset packets/callbacks cannot restore displaced state.
- Unsupported/malformed saved roots/records are retained unavailable, never normalized into defaults.
- Malformed archived campaign headers are retained but omitted from `ListInspectableCampaigns`.
- Local durable provider-owned writes call `GG.NotifyProviderChanged`.

## Lifecycle

```
login → Initialize(empty root) → EnsureGossipProvider (staged config only)
explicit CreateStagedRecord (verified editor) → staged record
New Campaign (confirmed) → empty items + immutable boundary + archive prior
config ops (bank tab / items / rank) → dormant staged only
gossip exchange → AdmitRemote* (authenticated sender) / pending / conflict
dataset mismatch → blocked until authorized editor adopts (replace)
Settings Configuration/Logs → banners; no Chat
#388 → evidence/accounting through same admission boundary
#389 → agreed live cutover eligibility + writer retirement
```

## Evidence

- `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py` (includes 3A provider/admission/adoption paths)
- Gossip idle/repair: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Settings navigation/layout when pages change
- Retail multi-client smoke steps in docs; never claim unperformed in-game QA
