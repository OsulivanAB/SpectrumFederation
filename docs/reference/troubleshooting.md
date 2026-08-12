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

These operations require admin status in the active profile. The profile owner is always an admin and cannot be removed through the settings page.

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

Bulk transfers pause while local or raid-wide safe mode is active. Disable the relevant safe mode or wait until combat restrictions have cleared.

## Raid Check shows Loading, Out of range, or Unavailable

WoW throttles inspection and requires other players to be nearby and inspectable.

- Open **Loot Helper → Equipment** and select **Refresh Snapshot**.
- Move closer to unresolved players.
- Wait for item links and inspection data to populate.
- Rerun the check after pending statuses resolve.

Raid Check intentionally avoids treating incomplete item data as a definite failure or awarding points from it.

## A player did not receive a Raid Check point

Confirm that:

- you ran **Raid Check**, not **Pre-Raid Check**;
- the player passed every enabled requirement;
- inspection was complete;
- the player belongs to the active profile;
- **Points Per Raid Check** is greater than zero.

The point change appears in Loot Logs with **Raid Check** as its author.

## A whisper was not sent

Check that whispers are enabled for the mode you ran. Prepared-player whispers have a separate toggle.

Missing-result whispers are sent at most once per profile member, check type, and calendar day. Players who are not in the profile can be inspected, but their daily whisper state cannot be stored as profile-member data.

## Settings changed after switching specialization

The Gameplay page intentionally controls WoW's Press and Hold Casting CVar per character specialization. Spectrum Federation reapplies the saved choice after login, reload, and specialization changes.

## Collect diagnostic information

1. Run `/sf debug on`.
2. Reproduce the problem.
3. Run `/sf debug show`.
4. Filter levels if needed.
5. Use `Ctrl+A` and `Ctrl+C` in the log viewer.

Turn debugging off afterward with `/sf debug off`. Diagnostic storage is capped at 500 entries.
