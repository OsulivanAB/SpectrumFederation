# Guild Info — Main / Alt Assignments

Guild Info is a **guild-owned**, directed main→alt relationship system. It is independent of Loot Helper profile identity links and Guild Supplies witness GUID groups. Issue contract: [#402](https://github.com/OsulivanAB/SpectrumFederation/issues/402).

Transport dependency: Guild Gossip ([#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378)). Guild Info does **not** require a Loot Helper session, raid, or Guild Supplies activation.

## Change contract

| Concern | Owner |
| --- | --- |
| Durable guild record / membership+group state / derived graph | `SF.GuildInfo` (`State`) |
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
- Concurrent edits converge by deterministic version tuples `(n, w)` (logical revision + writer nonce), not wall-clock timestamps alone.
- Storage scales with retained character/group identities, not lifetime edit count.

### Non-goals (this ticket)

- Import/migrate from Loot Helper or Guild Supplies identity data.
- Drive donation witness counting or Loot Helper profile permissions from Guild Info.
- Configurable editor rank policies or multi-level family trees.
- Append-only operation logs, cutovers, or compaction checkpoints.

## Saved schema (`schemaVersion = 2`)

```lua
SpectrumFederationDB.guildInfo = {
  schemaVersion = 2,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<actual club id>"] = {
      schemaVersion = 2,
      guildKey = "club:<id>",
      clubId = "<id>",
      members = {
        -- [guid] = {
        --   guid, groupId = "<id>" | false (unassigned tombstone),
        --   ver = { n = <int>, w = "<writer nonce>" },
        --   at = <server time>, nameRealm?, classFile?
        -- }
      },
      groups = {
        -- [groupId] = {
        --   groupId, mainGuid?, dissolved?,
        --   ver = { n, w }, at = <server time>
        -- }
      },
      characters = { -- display cache bounded to membership GUIDs
        -- [guid] = { guid, nameRealm, classFile }
      },
      graph = { -- derived from members+groups; not independently authoritative
        mains = { [mainGuid] = { mainGuid, groupId, altGuids = { ... } } },
        byGuid = { [guid] = { role = "main"|"alt", mainGuid, groupId } },
      },
      revision = <members + groups count>,
      openConflicts = {},
    },
  },
}
```

**Migration:** Schema 1 was the unmerged op-log prototype. On load, Guild Info performs a **Guild Info-only hard reset** to an empty schema-2 root. Guild Supplies, Loot Helper, and unrelated SavedVariables are never touched.

Durable keys are only `club:<id>`. Transport `name:` scopes are never persisted.

## Versioning and merge

- Each membership and group record carries `ver = { n, w }`.
- Higher `n` wins; equal `n` ties break on lexicographic writer nonce `w`.
- Wall-clock `at` is metadata/display only and never grants authority.
- Independent characters merge independently. Conflicting assignments to the same GUID resolve to one winner; unrelated edits survive.
- **Change Main** updates only the group’s `mainGuid` (and group version). Memberships keep the same stable `groupId`, so the logical promotion is atomic and does not rewrite every alt.
- Unassign writes `groupId = false` (tombstone). Stale lower-version assignments cannot resurrect the link.
- Empty groups (no remaining alts) dissolve: remaining solo main is tombstoned and the group is marked `dissolved`. Unreferenced dissolved groups may be reclaimed; membership tombstones are retained until the identity-capacity ceiling so offline peers cannot republish obsolete links.

## Capacity and cleanup

| Cap | Value | Behavior at limit |
| --- | --- | --- |
| `MAX_MEMBERS` | 256 | New GUID memberships fail closed (`members_overflow`) |
| `MAX_GROUPS` | 128 | Dissolved unreferenced groups are reclaimed before create; solo-main shells are retained/reused; forward aliases and inbound destinations are retained; live empty shells are never evicted; overflow fails closed if live+retained aliases fill the cap |
| `MAX_ALTS_PER_MAIN` | 32 | Assign rejected (`group_full`) |
| Gossip record | 2048 bytes CBOR | Oversize exports skipped / remote rejected |

**Group lifecycle:** `Assign → Unassign` of the same identities dissolves the empty group and keeps a dissolved tombstone for Gossip peers. When a new group would exceed `MAX_GROUPS`, unreferenced dissolved slots are reclaimed automatically so churn of the same identities cannot permanently exhaust capacity. Live group shells admitted group-first (memberships not yet arrived) are retained; capacity fails closed rather than discarding them. Physical Gossip indexes drop retired `gi-g:*` IDs on durable-change invalidation.

**Shared-group lifecycle (emptiness is not global):** Unassigning the last *locally visible* alt does **not** dissolve the group or tombstone the main. A reusable solo-main shell stays live (hidden from the mains-only Settings list) so an offline peer can still assign another alt to the same group id. Legitimate independent edits to different characters therefore survive Gossip in either delivery order.

**Solo-main demotion:** When that shell’s main becomes an alt of someone who has no group yet, the shell is **repurposed** (same group id, new `mainGuid`) so ordinary same-identity churn does not accumulate group ids or aliases. When the main instead joins an *existing* other group, the vacated shell is retired as a dissolved `forwardTo` alias (and inbound aliases are flattened onto the new destination) so memberships that still cite the old id remain visible under the new main. Rejecting demotion while waiting for “sync complete” is not used — Gossip cannot prove that, and indefinite alias retention would freeze the character.

**Forward-alias retention:** A dissolved group with `forwardTo` is an active dependency, not reclaimable garbage. `ReclaimUnreferencedDissolved` never deletes a forward alias or a group that still has inbound aliases, even when no currently received membership points at those IDs — absence of membership is incomplete Gossip, not proof the remote source is finished. Destinations with inbound forwards also refuse ordinary empty-group dissolution. Chains are followed with a bounded, cycle-safe walk (depth ≤ 8). At `MAX_GROUPS`, creates fail closed with `groups_overflow` / Settings feedback rather than silently dropping forwarding metadata. Tradeoff: indefinitely disconnected peers plus enough concurrent *unrelated* live+alias churn can exhaust capacity until an editor removes unused live groups; unbounded alias history is intentionally not kept.

**Concurrent first assign:** If two officers independently create groups for the same ungrouped main, the **derived graph** absorbs loser-group members into the canonical group (main’s durable membership group when present; otherwise highest group version). Automatic reconciliation does **not** rewrite durable membership/group versions or dissolve loser shells. Officer mutations against the displayed logical group stay consistent: Unassign keeps a solo-main physical group while any sibling live claimant exists (including membership-empty shells — absence is incomplete sync, not emptiness); Change Main consolidates currently known absorbed members into the canonical group with genuine local versions, then retires sibling claimants as dissolved `forwardTo` aliases so late memberships remain resolvable. At equal membership revision `n`, a live-group assignment beats an unassign tombstone. Unrelated established groups with different mains are never merged.

**Membership tombstones:** Unassigned membership rows are **not** deleted automatically. They remain until the 256-identity cap so stale peers cannot resurrect removed links. Hitting the cap surfaces truthful Settings feedback (`members_overflow`); recovery is to reuse an already-retained identity, not an unbounded offline history. Indefinitely disconnected editors that never receive current tombstones cannot be given unbounded write-back without either unbounded tombstone retention or resurrection risk.

## Gossip provider

Provider id: `sf.guildinfo.relationships` (`PROVIDER_SCHEMA = 2`).

| Wire kind | Record id | Body |
| --- | --- | --- |
| `guildinfo-member` | `gi-m:<guid>` | versioned membership |
| `guildinfo-group` | `gi-g:<groupId>` | versioned group |

Remote admission requires a transport-authenticated editor sender (rank ≤ min(3, rankCount)). Payload versions/authors never grant editing authority. Ordinary members may receive/view state but cannot originate or launder mutations.

## Public read API

| API | Contract |
| --- | --- |
| `GI:GetRelationshipGroups([guildKey])` | Sorted-ready group list; empty when unconfigured; hides mains-only rows |
| `GI:GetCharacterRole(guid[, guildKey])` | `"main"` / `"alt"` / nil |
| `GI:GetCapabilities()` | `canRead` / `canEdit` (UI hints; recheck at commit) |
| `GI:GetAssignmentDisplayRows(roster)` | Settings list rows with membership status |
| `GI.CountRetainedState([record])` | Bound diagnostics (members/groups/tombstones) |

Future Loot Helper / Guild Supplies integration may **read** these APIs. They must not become the authority for those systems in this ticket.

## Settings

Top-level **Guild Info** category → **Main / Alt Assignments** page:

- Class-colored roster autocomplete (offline-inclusive), snapshot refreshed on roster/guild events while visible.
- Grouped list with remove controls for editors; Change Main for the selected group.
- Feedback via section banners only (no normal game Chat).

## Validation

```bash
python -m pytest tests/test_guild_info.py
lua5.1 tests/lua/guild_info_tests.lua
python3 .github/scripts/lint_all.py
python3 .github/scripts/validate_packaging.py
```
