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

## Saved schema (`schemaVersion = 3`)

```lua
SpectrumFederationDB.guildInfo = {
  schemaVersion = 3,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<actual club id>"] = {
      schemaVersion = 3,
      guildKey = "club:<id>",
      clubId = "<id>",
      syncGen = { n = <int>, w = "<writer nonce>" }, -- guild-scoped sync generation
      baseline = {
        complete = true|false,
        memberCount = <int>,
        groupCount = <int>,
        contentFp = "<fingerprint>",
        sealRev = { n = <int>, w = "<writer nonce>" }, -- same-gen tip order
      },
      members = {
        -- [guid] = {
        --   guid, groupId = "<id>" | false (unassigned tombstone),
        --   ver = { n = <int>, w = "<writer nonce>" },
        --   at = <server time>, nameRealm?, classFile?
        -- }
      },
      groups = {
        -- [groupId] = {
        --   groupId, mainGuid?, dissolved?, forwardTo?,
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

**Migration:** Schema 1 (op-log prototype) hard-resets to an empty schema-3 root. Schema 2 (pre-epoch state) migrates in place: relationships are preserved and a bootstrap `syncGen` / sealed `baseline` is installed. Newer/unknown schemas (`schemaVersion > 3`) fail closed without mutating `db.guildInfo`. Guild Supplies, Loot Helper, and unrelated SavedVariables are never touched.

Durable keys are only `club:<id>`. Transport `name:` scopes are never persisted.

## Versioning and merge

- Each membership and group record carries `ver = { n, w }`.
- Higher `n` wins; equal `n` ties break on lexicographic writer nonce `w`.
- Wall-clock `at` is metadata/display only and never grants authority.
- Independent characters merge independently. Conflicting assignments to the same GUID resolve to one winner; unrelated edits survive.
- **Change Main** updates only the group’s `mainGuid` (and group version). Memberships keep the same stable `groupId`, so the logical promotion is atomic and does not rewrite every alt.
- Unassign writes `groupId = false` (tombstone) for the alt. Stale lower-version assignments cannot resurrect the link.
- Unassigning the last alt does **not** dissolve the group: the solo-main shell stays live and reusable for offline synchronization (see Shared-group lifecycle). Unreferenced dissolved groups without forward dependencies may be reclaimed; membership tombstones are retained until the identity-capacity ceiling or officer history cleanup.

## Capacity and cleanup

| Cap | Value | Behavior at limit |
| --- | --- | --- |
| `MAX_MEMBERS` | 256 | New GUID memberships fail closed (`members_overflow`) |
| `MAX_GROUPS` | 128 | Dissolved unreferenced groups are reclaimed before create; solo-main shells are retained/reused; forward aliases and inbound destinations are retained; live empty shells are never evicted; overflow fails closed if live+retained aliases fill the cap |
| `MAX_ALTS_PER_MAIN` | 32 | Assign rejected (`group_full`) |
| Gossip record | 2048 bytes CBOR | Oversize exports skipped / remote rejected |

**Group lifecycle:** `Assign → Unassign` keeps a reusable solo-main shell (hidden from the mains-only Settings list) so offline peers can still assign to the same group id. Dissolved `forwardTo` aliases appear when a solo main is demoted into an *existing* other group (or when concurrent shells are retired), not from ordinary last-alt Unassign. Obsolete shells, aliases, and unassign tombstones are reclaimed through authorized officer history cleanup (sync generation), not automatic dissolve-on-empty. When a new group would exceed `MAX_GROUPS`, unreferenced dissolved slots without forward dependencies may be reclaimed automatically; live empty shells and forward aliases are never evicted this way — overflow fails closed. Physical Gossip indexes drop retired `gi-g:*` IDs on durable-change invalidation.

**Shared-group lifecycle (emptiness is not global):** Unassigning the last *locally visible* alt does **not** dissolve the group or tombstone the main. A reusable solo-main shell stays live (hidden from the mains-only Settings list) so an offline peer can still assign another alt to the same group id. Legitimate independent edits to different characters therefore survive Gossip in either delivery order.

**Solo-main demotion:** When that shell’s main becomes an alt of someone who has no group yet, the shell is **repurposed** (same group id, new `mainGuid`) so ordinary same-identity churn does not accumulate group ids or aliases. When the main instead joins an *existing* other group, the vacated shell is retired as a dissolved `forwardTo` alias (and inbound aliases are flattened onto the new destination) so memberships that still cite the old id remain visible under the new main. Rejecting demotion while waiting for “sync complete” is not used — Gossip cannot prove that, and indefinite alias retention would freeze the character.

**Forward-alias retention:** A dissolved group with `forwardTo` is an active dependency, not reclaimable garbage. `ReclaimUnreferencedDissolved` never deletes a forward alias or a group that still has inbound aliases, even when no currently received membership points at those IDs — absence of membership is incomplete Gossip, not proof the remote source is finished. Destinations with inbound forwards also refuse ordinary empty-group dissolution. Chains are followed with a bounded, cycle-safe walk (depth ≤ 8). Reciprocal/cyclic aliases break deterministically onto the lexicographically minimum group id in the cycle so assigned members stay visible without inventing synthetic membership versions; cleanup fails closed (`cleanup_forward_cycle`) if assigned members would still be hidden. At `MAX_GROUPS`, creates fail closed with `groups_overflow` / Settings feedback rather than silently dropping forwarding metadata. Tradeoff: indefinitely disconnected peers plus enough concurrent *unrelated* live+alias churn can exhaust capacity until an editor removes unused live groups; unbounded alias history is intentionally not kept.

**Concurrent first assign:** If two officers independently create groups for the same ungrouped main, the **derived graph** absorbs loser-group members into the canonical group (main’s durable membership group when present; otherwise highest group version). Automatic reconciliation does **not** rewrite durable membership/group versions or dissolve loser shells. Officer mutations against the displayed logical group stay consistent: Unassign keeps a solo-main physical group while any sibling live claimant exists (including membership-empty shells — absence is incomplete sync, not emptiness); Change Main consolidates currently known absorbed members into the canonical group with genuine local versions, then retires sibling claimants as dissolved `forwardTo` aliases so late memberships remain resolvable. At equal membership revision `n`, a live-group assignment beats an unassign tombstone. Unrelated established groups with different mains are never merged.

**Membership tombstones:** Unassigned membership rows are **not** deleted automatically during normal Assign/Unassign. They remain until the 256-identity cap so same-generation stale peers cannot resurrect removed links. Hitting the cap surfaces truthful Settings feedback (`members_overflow`).

### Officer history cleanup / sync generation (Option B)

Ranks 1–3 may run **Clean up retained Guild Info history** in Settings. This is not Delete All Assignments.

- **Retains:** currently known valid main/alt relationships (including departed characters’ last-known display identity). Cleanup rebuilds memberships onto **canonical derived group ids** so absorbed/forwarded alts are not dropped when their physical `groupId` differs from the displayed home.
- **Discards:** empty solo-main shells, unassign tombstones, forwarding aliases, and other obsolete groups that are not part of a visible relationship.
- **Generation:** commits a new guild-scoped `syncGen` and sealed `baseline` (`memberCount` / `groupCount` / `contentFp` / `sealRev`). Older-generation member/group wires are rejected even with higher individual `ver.n`. Competing cleanups at the same `n` tie-break on lexicographic writer nonce `w`. Remote generations must use canonical writer ids (`bootstrap` or 24-hex) and counters that remain safely incrementable; invalid or exhausted generations fail closed before wipe.
- **Seal freshness:** after ordinary Assign/Unassign/Change Main (local or accepted remote) on a completed baseline, seal metadata and `sealRev` are refreshed to match durable rows so fresh peers can finish sync without the writer reloading.
- **Incomplete sync:** a follower that adopts a newer epoch wipes prior relationships and stays `baseline.complete = false` until the sealed counts/fingerprint match. Same-generation epoch tips follow `sealRev` order: a higher tip parks already-accepted rows in bounded `_sameGenHold` (chronological admit order plus per-sender streams), restarts catch-up, then seals only on an exact tip count/fingerprint match — from the durable tip buffer, from a global trailing tip-sized window, or from one of a bounded number of per-sender tip windows (O(hold) per trial, ≤1+senders fingerprints; no combinatorial subset search). Concurrent extras of any count are re-merged after seal so they can relay without source retransmission. Count supersets alone never complete a baseline. Peers that never receive any author's contiguous tip-sized export remain fail-closed (incomplete) rather than guessing. Relationship APIs report `generation_syncing` rather than an authoritative empty finished state. While incomplete, Gossip export advertises only the epoch meta record (never a partial completed baseline).
- **Generation bounds:** `syncGen` / `sealRev` writers must be `bootstrap` or 24-hex; counters must stay strictly below `MAX_SYNC_GEN_N` so ordinary cleanup can still advance. Invalid remote tuples are rejected before wipe. A currently authorized rank 1–3 officer remains trusted to publish any valid in-bound generation or seal revision, including the terminal advancable value `MAX_SYNC_GEN_N - 1`, after which ordinary cleanup/`sealRev` bumps report `generation_exhausted`. Mitigating that residual without rejecting legitimate long-offline catch-up requires a stronger trust/consensus boundary and is explicitly deferred.
- **Tradeoff:** the confirming officer’s known view becomes the new guild-wide baseline. Offline edits that never entered that baseline are intentionally invalidated. Cleanup works at capacity; if every slot is a genuine active relationship, Settings rejects with `cleanup_no_capacity` rather than a successful no-op.

## Gossip provider

Provider id: `sf.guildinfo.relationships` (`PROVIDER_SCHEMA = 3`).

| Wire kind | Record id | Body |
| --- | --- | --- |
| `guildinfo-epoch` | `gi-e:current` | `{ gen, memberCount, groupCount, contentFp, sealRev? }` |
| `guildinfo-member` | `gi-m:<guid>` | versioned membership + `gen` |
| `guildinfo-group` | `gi-g:<groupId>` | versioned group + `gen` |

Schema-2 (epochless) wires are rejected. Remote admission requires a transport-authenticated editor sender (rank ≤ min(3, rankCount)). Payload versions/authors/epochs never grant editing authority by themselves. Ordinary members may receive/view state but cannot originate or launder mutations.

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
