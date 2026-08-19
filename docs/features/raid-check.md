# Raid Check

Raid Check inspects group members' current equipment against requirements stored in the active loot profile. It can report missing gear, enchants, and gems, optionally whisper results, and award points to prepared profile members.

Only an admin of the active profile can run or configure a check.

## Configure requirements

Open **Loot Helper → Profile → Raid Check Profile Settings**.

For each profile, admins can choose:

- the point award per successful Raid Check: `0`, `0.5`, or `1`;
- whether every socket on socketed equipment must contain a gem;
- whether at least one meta gem is required;
- which equipment categories require enchant checks.

All enchant categories and socketed-gem checks are enabled for a new profile. The meta-gem requirement is disabled, and the default point award is `0.5`.

## Pre-Raid Check and Raid Check

Both modes inspect every available party or raid unit.

**Pre-Raid Check**

- reports missing configured requirements to the admin who ran the check as system messages;
- can whisper offenders who are missing requirements when that setting is enabled;
- does not award points.

**Raid Check**

- reports missing configured requirements to the admin who ran the check as system messages;
- awards the configured amount to each prepared player who belongs to the active profile;
- skips point awards for prepared players who are not profile members;
- can whisper missing and prepared results when those settings are enabled.

Run checks from **Loot Helper → Session**, or use `/sf raidcheck pre` and `/sf raidcheck raid`.

## Inspect-data limitations

WoW only exposes another player's equipment when that player can be inspected. Results may temporarily show **Loading**, **Out of range**, **Unavailable**, or a saved snapshot while fresh data is collected.

Raid Check does not treat partial item data as a definite failure and does not award points until the inspection is usable. Inspect stubs can already show a base item level and empty sockets from the item tooltip before gems and enchants populate; bonus IDs and item context are the signals that the inspect has resolved. Move close to unresolved players and refresh the equipment snapshot before rerunning the check.

## Equipment audit page

Open **Loot Helper → Equipment** to review the current inspection snapshot. The page shows:

- each visible member and average item level;
- the last known item in each tracked category;
- pulsing red indicators for missing items, required enchants, or gems;
- status text when inspection is loading, stale, or out of range.

Use **Refresh Snapshot** for a short manual inspection pass. **Enable Auto Refresh** keeps inspection active while the page is open. WoW inspection is throttled, so a full raid may populate gradually.

Saved profile snapshots allow absent members or temporarily unavailable inspection data to remain visible, but the page labels stale or saved information.

## Whispers

Whispers are disabled by default. Admins can enable them separately for Pre-Raid Check and Raid Check. Whisper settings do not control the admin-facing system-message summary; that summary always lists every player who is missing configured requirements.

Templates support:

- `{player_name}`
- `{missing}`
- `{point_name}`
- `{points_awarded}`

For missing requirements, the addon records when each profile member was whispered and suppresses repeated whispers of the same check type on the same calendar day. Prepared-player whispers are controlled separately and are sent only after a successful Raid Check point award.

## What gets recorded

Raid Check point awards are normal point-change log entries with **Raid Check** as the author and can be reviewed on the [Loot Logs](loot-logs.md) page.
