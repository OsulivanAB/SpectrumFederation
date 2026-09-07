# RC Loot Council Integration

The optional child addon `SpectrumFederation_RCLootCouncilIntegration` records finalized RC Loot Council awards in Spectrum Loot Logs while a Spectrum Loot Helper session is active.

It does not send RC messages, persist raw RC traffic, or keep its own SavedVariables.

## When it records

Recording requires all of the following:

- the child addon is enabled;
- a Spectrum Loot Helper session is active;
- the award belongs to the profile attached to that session;
- the local client is an admin of the session profile;
- that profile's RC integration settings allow that response.

The locally selected Loot Helper profile is not used for live recording. If the session `profileId` cannot be resolved locally, the award is ignored rather than written to another profile.

The Loot Log **Author** is the RC master looter who awarded the item. The Spectrum writer must still be an admin of the session profile. Any eligible Spectrum admin may create the log; there is no coordinator-only writer restriction.

If the winner is not a member of the session profile, no Loot Log is created. Admins of the session profile see a local warning only. Replay and reload do not repeat that warning for the same award in the same session.

## Settings

Open `/sf` → **Loot Helper → RC Loot Council**. The page appears only when this child addon is enabled. It does not add a redundant **Optional** sidebar row.

While a Loot Helper session is active, the page shows and edits that session profile's RC settings, because those settings control live recording. With no session, it uses the currently selected Loot Helper profile.

Settings are profile-scoped and admin-editable:

- **Record RC Loot Council Awards in Loot Logs** (default on)
- **Record all award types** (default on)
- **Allowed Award Types** when record-all is off

Matching is case-insensitive after trimming. The original RC response text is stored on the Loot Log. Empty and duplicate allow-list entries are rejected.

These settings sync with the profile snapshot as `snapshot.rcLootCouncilIntegration`, using the same profile-snapshot path as Raid Check. Changing them does not create a visible Loot Log row. Older snapshots may still carry unused `snapshot.rcLootCouncil` metadata; that field remains compatibility-only and is not the live integration.

Defaults fill in for older profiles that have no stored RC configuration.

## Loot Log shape

Recorded awards use type `RC_LOOT_COUNCIL`:

- **Type of Change** — RC Loot Council
- **Member** — loot recipient
- **Action** — the WoW item link (hoverable and clickable in Loot Logs)
- **Author** — RC master looter / awarder
- persisted audit fields include the original RC response, `history.id`, and the deterministic award key

## Award identity

The primary finalized RC signal is the RC `history` payload. RCLootCouncil2 serializes `command` plus one `data` table (`Serialize(command, data)`). For `Send(..., "history", winner, history_table)` that is `command = "history"` and `data = { winner, history_table }`. Cross-realm wraps that as `command = "xrealm"` and `data = { target, "history", winner, history_table }`; Spectrum unwraps the inner command only when the target is the local player.

Remote `history` is accepted only when the AceComm sender is the current RC master looter for this client (`masterLooter` / `GetML()` / `IsMasterLooter()`). Unrelated guild `history` from another RC raid is ignored. The local master-looter path is AceEvent `RCMLLootHistorySend` and does not re-check the sender, because RC fires that message only on the ML client. Both paths normalize the same award into the same external identity and the same deterministic Loot Log contents.

Identity is derived from finalized history data available to every observer:

`RCLootCouncil|<normalizedAwarder>|<history.id>|<normalizedWinner>|<itemString>|<normalizedOwner or "">`

The human-readable response label is audit data only and is not part of the key. Spectrum ignores RC `delete_history`; a new `history.id` is a new Spectrum event.

## Sync isolation

External IDs and sentinel counter `0` are a narrow `RC_LOOT_COUNCIL` exception. Ordinary event types must keep `_id == author:counter` with a positive sequential counter and must not carry `_externalId`.

Valid RC external rows require all of:

- `_externalId` is the canonical award key
- `_id` equals `_externalId`
- `_counter` is the sentinel `0`
- `_data.awardKey` is present and equals `_externalId`
- they do not allocate or advance ordinary author counters
- they do not enqueue gap, integrity, `AUTH_LOGS`, or convergence repair
- a same-id / different-fingerprint collision keeps the first stored row and does not request sequential repair

Ordinary sequential Loot Logs keep their existing repair and sync behavior.

Mixed-version clients that do not understand `_externalId` drop only the RC row. A snapshot is not invalidated by the presence of one RC log.

## Limits

- If RC has both history options off, or `reason.log` is false, there is no history object and Spectrum cannot record the award.
- If RC history is self-only or guild-only, other Spectrum admins may not observe the remote `history` message. The master looter still has `RCMLLootHistorySend`.
- The parent addon does nothing RC-specific when this child is absent or disabled.
