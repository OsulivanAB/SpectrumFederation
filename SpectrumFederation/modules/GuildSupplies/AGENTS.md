# Guild Supplies Phase 2A — Change Contract (#385)

Zip-excluded guidance (`*/AGENTS.md`). Canonical schema/API docs: `docs/development/guild-supplies/`.

## Authority

| Concern | Owner |
| --- | --- |
| Staged durable guild records | `SF.GuildSupplies` account root (`SpectrumFederationDB.guildSupplies`) |
| Live donation/config writes | Legacy profile-scoped Consumables only |
| Current guild/rank proof | Demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` (not idle gossip cache) |
| Preview as Non-Admin | `SF.LootHelperImpersonation` overlay |

## Guarantees

1. Reads/startup never create per-guild records; `CreateStagedRecord` is explicit.
2. Durable key is only `club:<actual id>`; `name:` transport scopes are rejected.
3. Default editor threshold is logical rank position 3; labels use actual rank names.
4. Invalid/out-of-range policy permits verified Guild Master recovery only.
5. Staged compare-and-apply statuses: accepted / duplicate / pending / rejected.
6. Zero active gossip providers still support demand-driven authority (throttled cold-roster nudge only); missing data fails closed; commit rechecks guild/rank/policy.
7. Chat-free: enabled `SF.Debug` only. No Guild Supplies provider registration in 2A.

## Dependencies / invalidation

- Actual club ID, local GUID/name, rank order/names, accepted permission revision.
- Guild key change bumps handle generation; prepared ops cannot commit across it.
- Unsupported/malformed saved roots/records are retained unavailable, never normalized into defaults.

## Lifecycle

```
login → Initialize(empty root)
explicit CreateStagedRecord (verified editor) → staged record
New/Validate/Apply staged ops → dormant only
no provider → gossip adapter remains idle
```

## Evidence

- `tests/lua/guild_supplies_tests.lua` via `tests/test_guild_supplies.py`
- Gossip idle/repair: `tests/test_guild_gossip.py`
- Consumables regressions: `tests/test_consumables.py`
- Retail rank/readiness remains human QA
