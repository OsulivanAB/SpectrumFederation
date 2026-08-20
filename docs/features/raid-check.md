# Raid Check

Raid Check inspects group members' current equipment against requirements stored in the active loot profile. It can report missing gear, enchants, and gems, optionally whisper results, and award loot points or Attendance to prepared profile members.

Only an admin of the active profile can run or configure a check.

## Configure requirements

Open **Loot Helper → Profile → Raid Check Profile Settings**.

For each profile, admins can choose:

- in [Point Based](point-based.md) mode, the loot-point award per successful Raid Check: `0`, `0.5`, or `1`;
- whether every socket on socketed equipment must contain a gem;
- whether at least one meta gem is required;
- which equipment categories require enchant checks.

All enchant categories and socketed-gem checks are enabled for a new profile. The meta-gem requirement is disabled, and the default Point Based award is `0.5`.

In [Reward Pot](reward-pot.md) mode, **Points Per Raid Check** is hidden. Prepared members receive `1` Attendance instead, and the pot uses the profile's Raid Check deduction settings.

## Who is evaluated

**Pre-Raid Check** and **Raid Check** both inspect profile members who are currently in the raid. Players who are in the raid but not in the profile are ignored. Players who are in the profile but not in the raid are ignored.

## Pre-Raid Check and Raid Check

**Pre-Raid Check**

- reports missing configured requirements and missing inspect data to the admin who ran the check as system messages;
- can whisper players who are missing configured enchants or gems when that setting is enabled;
- does not award loot points or Attendance;
- does not change the Reward Pot.

**Raid Check**

- reports missing configured requirements and missing inspect data to the admin who ran the check as system messages;
- in Point Based mode, awards the configured loot points to each prepared profile member in the raid;
- in Reward Pot mode, awards `1` Attendance to each prepared profile member in the raid;
- in Reward Pot mode, subtracts from the pot once if any evaluated member is unprepared;
- can whisper missing and prepared results when those settings are enabled.

A member with no usable inspect data is unprepared. That includes out of range, never inspected, and incomplete item data. Inspect gaps are listed in the admin summary and do not send a missing-gear whisper.

Run checks from **Loot Helper → Session**, or use `/sf raidcheck pre` and `/sf raidcheck raid`.

Running Raid Check more than once can award points or Attendance again and, in Reward Pot mode, deduct from the pot again.

## Inspect-data limitations

WoW only exposes another player's equipment when that player can be inspected. Results may temporarily show **Loading**, **Out of range**, **Unavailable**, or a saved snapshot while fresh data is collected.

Inspect stubs can already show a base item level and empty sockets from the item tooltip before gems and enchants populate. Move close to unresolved players and refresh the equipment snapshot before rerunning the check.

## Equipment audit page

Open **Loot Helper → Equipment** to review the current inspection snapshot. The page shows:

- each visible member and average item level;
- the last known item in each tracked category;
- pulsing red indicators for missing items, required enchants, or gems;
- status text when inspection is loading, stale, or out of range.

Use **Refresh Snapshot** for a short manual inspection pass. **Enable Auto Refresh** keeps inspection active while the page is open. WoW inspection is throttled, so a full raid may populate gradually.

Saved profile snapshots allow absent members or temporarily unavailable inspection data to remain visible, but the page labels stale or saved information.

## Whispers

Whispers are disabled by default. Admins can enable them separately for Pre-Raid Check and Raid Check. Whisper settings do not control the admin-facing system-message summary; that summary always lists every evaluated player who is missing configured requirements or inspect data.

Templates support:

- `{player_name}`
- `{missing}`
- `{point_name}`
- `{points_awarded}`

For missing requirements, the addon records when each profile member was whispered and suppresses repeated whispers of the same check type on the same calendar day. Prepared-player whispers are controlled separately and are sent only after a successful Raid Check award. In Reward Pot mode, `{point_name}` in both missing and prepared whispers uses Attendance rather than the profile's loot-point name.

## What gets recorded

Point Based awards are loot-point log entries with **Raid Check** as the author. Reward Pot awards are Attendance log entries with the same author. A Reward Pot deduction is a Reward Pot change with **Raid Check** as the author. Review them on the [Loot Logs](loot-logs.md) page.
