# Raid Signup

Raid Signup is a **guild-owned** season/tier roster planner under **Raid Tools**. It is independent of Loot Helper profiles and sessions. Issue contract: [#404](https://github.com/OsulivanAB/SpectrumFederation/issues/404).

Transport dependency: Guild Gossip ([#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378)). Officer plan management uses the shared guild officer threshold ([#405](https://github.com/OsulivanAB/SpectrumFederation/issues/405)).

## Change contract

| Concern | Owner |
| --- | --- |
| Durable plans + entries | `SF.RaidSignup` State (`SpectrumFederationDB.raidSignup`) |
| Officer / creator authorization | Authority via `SF.GuildOfficer` + `creatorGuid` |
| Local mutations | Operations |
| Authenticated Gossip provider | Gossip (`sf.raidsignup.roster`) |
| Planned coverage | Coverage (mains only) |
| Settings UI | `UI/Settings/Pages/RaidSignup.lua` |

### Guarantees

- Free-text nicknames; no roster autocomplete or main/alt integration.
- Drafts are local UI state only. Nickname typing uses an Enter / focus-loss commit
  boundary so class/spec-first flows do not persist on the first nickname character.
  Persist/sync only when nickname (committed) + class + valid spec are complete;
  abandoned incomplete drafts are discarded.
- Creators and officers can edit saved nicknames with `expectedVer` stale-edit protection.
- At most one alternative; never identical main/alt class+spec.
- Local mutations against archived plans are rejected. Remote Gossip may still catch up
  already-saved historical roster contents onto archived plans; the UI stays read-only.
- Deletions use versioned tombstones. There is no restore: a live record never overwrites
  a tombstone, regardless of version order or writer tie-break. New Add Row uses new IDs.
- Concurrent edits converge by `(n, w)` version tuples for live records.
- Coverage summary uses ability/utility category icons (not class-icon stand-ins) with
  greyed missing state; the selected main-spec icon sits next to the nickname (notes do
  not separate them).
- Typing does not rebuild the settings page; durable board hosts are reused. Idle visible
  page does not poll or broadcast.

### Gossip multi-hop note

Phase 1 Guild Gossip authenticates the current hop sender. Member-authored entries admit when the transport sender is the creator or an officer. Non-officer relays of someone else's newer entry return `relay_lacks_authority`. Peers still converge when they pull from the author or through an officer hub.

**Repair finding 7 (paused):** ordinary members holding saved data still cannot relay newer third-party entries when authors/officers are offline. Resolving that without weakening creator/officer **edit** rights requires an explicit trust-model choice (Guild Supplies–style membership replica catch-up vs keeping the limitation). See the repair decision note; do not silently weaken admission gates.

## Saved schema (`schemaVersion = 1`)

```lua
SpectrumFederationDB.raidSignup = {
  schemaVersion = 1,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<id>"] = {
      schemaVersion = 1,
      guildKey = "club:<id>",
      clubId = "<id>",
      selectedPlanId = "<planId>" | nil, -- local UI preference; not gossiped
      plans = { -- [planId] = { planId, name, archived, createdBy, ver={n,w}, at } },
      entries = { -- [entryId] = { entryId, planId, nickname, mainClass, mainSpec,
                  --   altClass?, altSpec?, notes, creatorGuid, deleted?, ver, at } },
    },
  },
}
```

Wire kinds: `raidsignup-plan`, `raidsignup-entry`. Record IDs: `rs-p:<planId>`, `rs-e:<entryId>`.

## Validation

- `python -m pytest tests/test_raid_signup.py`
- `python3 .github/scripts/lint_all.py`
- `python3 .github/scripts/validate_packaging.py`
- Docs: `python3 .github/scripts/validate_docs.py`
- Human Retail QA after review (plan CRUD, draft/alt flows, sync with two clients)
