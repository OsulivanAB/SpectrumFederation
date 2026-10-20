# Guild Info — Main / Alt Assignments

Guild Info is a **guild-owned**, directed main→alt relationship system. It is independent of Loot Helper profile identity links and Guild Supplies witness GUID groups. Issue contract: [#402](https://github.com/OsulivanAB/SpectrumFederation/issues/402).

Transport dependency: Guild Gossip ([#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378)). Guild Info does **not** require a Loot Helper session, raid, or Guild Supplies activation.

## Change contract

| Concern | Owner |
| --- | --- |
| Durable guild record / op log / derived graph | `SF.GuildInfo` (`State`) |
| Verified ranks 1–3 (fixed; not GS policy) | `Authority` via demand-driven `GG.GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` |
| Local assign / unassign / change-main | `Operations` |
| Roster snapshot, suggestions, membership status | `Roster` |
| Authenticated Gossip provider | `Gossip` (`sf.guildinfo.relationships`) |
| Settings UI | `UI/Settings/Pages/MainAltAssignments.lua` |

### Guarantees

- Strict hierarchy: a character is unassigned, a main of one group, or an alt of exactly one main.
- No cycles, nesting, or dual ownership.
- One authorized officer edit is enough (no three-witness quorum).
- Departed characters retain relationships; incomplete roster data is **unknown**, not departure.
- Concurrent ops converge by deterministic fold ordered by `(at, opId)`.

### Non-goals (this ticket)

- Import/migrate from Loot Helper or Guild Supplies identity data.
- Drive donation witness counting or Loot Helper profile permissions from Guild Info.
- Configurable editor rank policies or multi-level family trees.

## Saved schema

```lua
SpectrumFederationDB.guildInfo = {
  schemaVersion = 1,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<actual club id>"] = {
      schemaVersion = 1,
      guildKey = "club:<id>",
      clubId = "<id>",
      ops = { -- [opId] = operation body },
      order = { "<opId>", ... }, -- admission order; fold sorts by (at, id)
      characters = { -- [guid] = { guid, nameRealm, classFile } last-known display },
      graph = { -- derived
        mains = { [mainGuid] = { mainGuid, altGuids = { ... } } },
        byGuid = { [guid] = { role = "main"|"alt", mainGuid = <guid> } },
      },
      revision = <number of accepted ops>,
      openConflicts = {},
    },
  },
}
```

Durable keys are only `club:<id>`. Transport `name:` scopes are never persisted.

## Operations

| Kind | Effect |
| --- | --- |
| `assign` | Place alt under main (idempotent if already there; move when confirmed) |
| `unassign` | Remove one alt from its main |
| `change_main` | Promote a rostered alt; previous main becomes an alt; other alts retained |
| `cutover` | Replicated compaction boundary: clears prior graph; `coveredIds` lists incorporated ops |
| `snapshot` | Legacy compaction marker (fold-supported); not emitted by new compaction |

Remote admission requires a transport-authenticated editor sender (rank ≤ min(3, rankCount)). Authorization is the transport sender only; payload `actorGuid` is provenance kept version-stable for editor-to-editor relay/catch-up and is never treated as authentication.

Compaction is a bounded replicated cutover produced only by a **local editor commit** (remote ingest never manufactures a cutover from a partial view). The editor replaces its incorporated log with one `cutover` (including explicit `coveredIds`) plus officer-authored per-relationship assign checkpoints (each within Guild Gossip’s 2048-byte record cap). Peers purge only ops listed in `coveredIds`; independent edits the compactor never observed are retained and applied after cutover/checkpoints. The pending edit that triggered compaction is folded into the checkpoint graph and listed in `coveredIds` so same-second `(at,id)` ordering cannot acknowledge an Unassign while checkpoints recreate the removed link. If `coveredIds` cannot fit the Gossip record cap, compaction fails closed and the admit is refused with `ops_overflow` (capacity limitation) rather than silently dropping accepted work.

## Public read API

| API | Contract |
| --- | --- |
| `GI:GetRelationshipGroups([guildKey])` | Sorted-ready group list; empty when unconfigured |
| `GI:GetCharacterRole(guid[, guildKey])` | `"main"` / `"alt"` / nil |
| `GI:GetCapabilities()` | `canRead` / `canEdit` (UI hints; recheck at commit) |
| `GI:GetAssignmentDisplayRows(roster)` | Settings list rows with membership status |

Future Loot Helper / Guild Supplies integration may **read** these APIs. They must not become the authority for those systems in this ticket.

## Settings

Top-level **Guild Info** category → **Main / Alt Assignments** page:

- Class-colored roster autocomplete (offline-inclusive), snapshot refreshed on roster/guild events while visible.
- Grouped list with remove controls for editors; Change Main for the selected group.
- Feedback via section banners only (no normal game Chat).

## Validation

```bash
python -m pytest tests/test_guild_info.py
python3 .github/scripts/lint_all.py
python3 .github/scripts/validate_packaging.py
```
