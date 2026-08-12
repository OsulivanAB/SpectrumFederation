# Sync Sessions

A Loot Helper sync session keeps one profile consistent across addon users in the same party or raid. Profiles are synchronized from their append-only change logs, so clients transfer only missing history when possible.

## Start and end a session

Any admin of the selected profile can start a session while in a party or raid. Raid leadership is not required.

Start or stop from:

- the play/stop button on the Loot Helper window;
- **Loot Helper → Session → Session Control**;
- `/sf loot session start` and `/sf loot session end`.

The client that starts the session becomes its coordinator. Only that coordinator can explicitly end it. Leaving the group clears the local active-session state.

## What happens automatically

At session start, the coordinator:

1. rebuilds local member state from the profile logs;
2. compares log summaries with online profile admins;
3. requests any history it is missing;
4. selects up-to-date admin helpers;
5. announces the session and profile to the group.

Other addon users then:

- request the profile if they do not have it;
- request missing log ranges if their copy is behind;
- ignore duplicate log entries;
- receive new admin changes while the session is active.

Helpers can serve profile snapshots and log ranges, distributing larger transfers instead of routing everything through one player. Late joiners receive the current session announcement automatically.

## Manual sync

Enter `/sf loot sync` when you want your client to compare itself with the current coordinator immediately. The command reports whether:

- a full profile was requested;
- missing logs were requested;
- a request was already in progress; or
- the local profile already matches the session.

The coordinator cannot use this command because its profile defines the announced session state.

## Coordinator continuity

The coordinator sends heartbeats. If it disappears, eligible admins can take over the existing session using a newer coordinator epoch. The new coordinator re-announces the same profile and clients reject older coordinator control messages.

Active session identity is saved locally so a reload or world transition can restore the session when the player is still grouped. Transient request and convergence state is rebuilt after restoration.

## Safe modes

Safe mode pauses bulk synchronization and profile transfers. Small control traffic and the local profile remain available.

**Local safe mode**

- affects only your client;
- can be enabled all the time;
- can enable automatically when your character enters combat.

**Session safe mode**

- is supported by the synchronization protocol and can be coordinated across the session;
- can be requested only by an authorized profile admin;
- pauses participating clients when the coordinator accepts the request.

/// warning | Current settings limitation
The **All the Time** and **Only in-combat** raid-wide safe-mode options are saved on the profile, but the current settings/runtime integration does not apply them to the active sync session. Local safe mode works; do not rely on the two raid-wide settings until that integration is completed.
///

Safe mode is useful during combat or when you want to defer larger transfers. It does not delete data, end the session, or turn off Loot Helper.

## Permissions and trust

The sync layer validates that data senders are in the group and authorized for the profile. Live changes are accepted from the coordinator or authorized profile admins; snapshots and bulk log ranges are accepted only from the coordinator or selected helpers.

If profile admin lists differ between clients, the coordinator's pre-session convergence is important. Resolve admin membership before relying on another player to write shared data.

## Current limitation

The **Trigger Raid-Wide Sync** button in Session settings is a visible placeholder and is not implemented. Use `/sf loot sync` on an individual non-coordinator client when a manual comparison is needed.
