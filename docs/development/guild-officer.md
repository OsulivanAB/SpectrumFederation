# Guild officer rank

One guild-owned officer threshold per verified `club:<id>` guild. Issue contract: [#405](https://github.com/OsulivanAB/SpectrumFederation/issues/405).

Guild Info, Guild Supplies, and the one-time Loot Helper admin grant read this policy. They do not keep a second live rank setting.

## Contract

| Concern | Owner |
| --- | --- |
| Stored threshold, bootstrap, and commit | `SF.GuildOfficer` (`Policy`) |
| Gossip record | `Gossip` provider `sf.guildofficer.policy` |
| Native rank and guild identity | Guild Gossip `GetGuildIdentity` / `GetGuildMember` / `GetGuildRanks` |
| Settings selector | Guild Info → Main / Alt Assignments, top of the page |

- Positions are 1-based. Guild Master is rank 1. A member is an officer when `rankOrder <= threshold`.
- The default is rank 3, capped to the last existing native rank. A shorter rank list caps checks and display. It does not rewrite the stored value and it does not widen who qualifies.
- An empty local cache is unknown, not "never configured". Editing stays disabled until a valid record is stored or a verified Guild Master bootstraps or recovers it. Bootstrap does not overwrite a valid policy.
- Any verified member can view the effective policy. An officer may change it. Authority is rechecked when the change is committed and when a remote record is admitted.
- A self-restricting edit is authorized against the previous threshold. After it lands, that officer loses further edit rights.
- Same-revision concurrent edits keep the lower (more restrictive) threshold. A later revision replaces it, including a deliberate widen by someone who still qualifies. A lower revision is stale.
- The policy is independent of Guild Supplies datasets, Loot Helper profiles, and Guild Info relationship cleanup.

Disconnected clients may briefly use an older threshold. That limitation is accepted. This is not a consensus log.

## Storage

```lua
SpectrumFederationDB.guildOfficer = {
  schemaVersion = 1,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<id>"] = {
      schemaVersion = 1,
      guildKey = "club:<id>",
      threshold = 3,
      baseThreshold = 0, -- 0 = bootstrap/recovery; otherwise the previous stored threshold
      revN = 1,
      revW = "<24 hex>",
      at = 0,
    },
  },
}
```

Gossip publishes one current record, `go-p:current`, kind `guild-officer-policy`. There is no per-frame roster poll and no operation history.

## Consumers

- **Guild Info.** Assign, move, unassign, Change Main, and history cleanup use the shared threshold for local commits and authenticated remote mutations. Cleanup does not replace the threshold.
- **Guild Supplies.** Configuration, initialization, campaigns, and maintenance use the shared threshold. `permission.editorRankPosition` stays on existing records so historical validation and replica ancestry still work. It does not decide who can edit. The Settings editor-rank control only repairs a corrupt stored permission record.
- **Loot Helper.** Adding a new character to an existing profile may grant profile admin once, through the existing admin log, when that character's native guild rank meets the policy. Profile creation, import, hydration, snapshot replay, and remote rebuilds do not grant. Unknown or ambiguous verification adds a regular member. Later demotion, threshold changes, and manual admin removal do not scan or regrant.
