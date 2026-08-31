# Troubleshooting

## The Loot Helper window does not appear

Check these conditions:

1. **Loot Helper → General → Enable LootHelper** is enabled.
2. A profile is selected under **Loot Helper → Profile**.
3. You are in a raid, or **Show Loot Window outside of Raid** is enabled.

Enter `/sf loot` to enable the feature and re-evaluate visibility. If it still does not appear, enable diagnostics with `/sf debug on`, repeat the action, then open `/sf debug show`.

## A profile member is missing from the roster

By default, the roster can hide profile members who are not in the current raid. Enable **Show Members not in raid**.

A current raid member who is not in the profile appears as an addable row only for profile admins.

## I cannot change points, equipment, or profile settings

These operations require admin status in the active profile. Changing loot mode requires the profile owner. The profile owner is always an admin and cannot be removed through the settings page.

If a recently changed admin list differs between clients, synchronize the profile or restart the session after admins have converged.

## A sync session will not start

The starter must:

- be in a party or raid;
- have the selected profile locally;
- be an admin of that profile.

Raid leadership is not required. Use `/sf activeprofile` to confirm the selected profile and `/sf debug show` for the rejection reason.

## My profile is behind the session

Use `/sf loot sync` on the affected client. It requests a snapshot or missing log ranges only when needed.

The coordinator cannot request a manual catch-up from itself. If the wrong client is coordinating, end the session and have the intended up-to-date admin start a new one.

Runtime safe mode pauses profile and log transfers, but the visible local and raid-wide safe-mode settings are not currently wired to that runtime state. Toggling those settings will not repair a stalled transfer. If sync diagnostics report safe mode active unexpectedly, have the coordinator end and restart the session and include `/sflhsync status` in the bug report.

## Raid Check shows Loading, Out of range, or Unavailable

WoW throttles inspection and requires other players to be nearby and inspectable.

- Open **Loot Helper → Equipment** and select **Refresh Snapshot**.
- Move closer to unresolved players.
- Wait for item links and inspection data to populate.
- Rerun the check after pending statuses resolve.

Raid Check treats incomplete item data as unprepared. Move closer, refresh the snapshot, then rerun the check.

## `/sf version` shows a red X for someone who has the addon

The version window asks current group members to report the addon version they are running. A red X means that player did not answer in time.

Common causes:

- the player does not have Spectrum Federation enabled;
- the player is offline or still loading;
- the player is on an older build that does not answer version queries.

Run `/sf version` again after they reload. Your own row always shows the version from this client.

## A player did not receive a Raid Check point or Attendance

Confirm that:

- you ran **Raid Check**, not **Pre-Raid Check**;
- the player passed every enabled requirement;
- inspection was complete;
- the player belongs to the active profile and is in the raid;
- in Point Based mode, **Points Per Raid Check** is greater than zero.

The award appears in Loot Logs with **Raid Check** as its author. In Reward Pot mode, prepared players receive Attendance rather than loot points.

## A whisper was not sent

Check that whispers are enabled for the mode you ran. Prepared-player whispers have a separate toggle.

Missing-result whispers are sent at most once per profile member, check type, and calendar day. Players who are not in the profile can be inspected, but their daily whisper state cannot be stored as profile-member data.

## Collect diagnostic information

1. Run `/sf debug on`.
2. Reproduce the problem.
3. Run `/sf debug show`.
4. Filter levels if needed.
5. Use `Ctrl+A` and `Ctrl+C` in the log viewer.

Turn debugging off afterward with `/sf debug off`. Diagnostic storage is capped at 500 entries.
