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
- Drafts are local UI state only; persist/sync only when nickname + class + valid spec are complete.
- At most one alternative; never identical main/alt class+spec.
- Archived plans are read-only until reopened by an officer.
- Deletions use versioned tombstones; stale live records cannot resurrect deleted entries.
- Concurrent edits converge by `(n, w)` version tuples.
- Idle visible page does not rebuild, poll, or broadcast.

### Gossip multi-hop note

Phase 1 Guild Gossip authenticates the current hop sender. Member-authored entries admit when the transport sender is the creator or an officer. Non-officer relays of someone else's newer entry return `relay_lacks_authority`. Peers still converge when they pull from the author or through an officer hub.

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
