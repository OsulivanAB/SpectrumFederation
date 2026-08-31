# Raid Check

Raid Check inspects profile members who are currently in the group against **addon-owned current-Retail** enchant and gem rules, then optionally whispers results and awards loot points or Attendance.

Only an admin of the selected loot profile can run a check. Equipment rules are not configured per profile.

## Where to look

- **Raid Equipment** is a top-level Loot Tools category. It works with no loot profile and no Loot Helper session.
- **Pre-Raid Check** and **Raid Check** remain on **Loot Helper → Session**.
- Point awards, whispers, and Reward Pot deduction settings also remain on **Loot Helper → Session**.

## Current equipment rules

Prepared means a complete inspect of current gear found:

- an item in every tracked slot, except a legitimate empty Off Hand when Main Hand is a two-handed weapon;
- enchants on Head, Shoulders, Chest, Legs, Boots, both rings, and Main Hand;
- an Off Hand enchant only when that item is an actual weapon (`INVTYPE_WEAPON`, `INVTYPE_WEAPONOFFHAND`, or `INVTYPE_WEAPONMAINHAND`);
- no weapon enchant required for shields, held-in-offhand items, relics, or other non-weapon offhands;
- every socket filled;
- if the player has one or more usable sockets, exactly one current-expansion limited gem (Midnight Eversong Diamond family). Zero sockets requires zero limited gems.

A real empty slot is not the same as unresolved equipment. Missing item links, unresolved offhand type, or an unidentified limited gem make the observation **incomplete**. Incomplete inspects are **Inspection Failed**, not Unprepared.

## Raid Equipment page

Open **Raid Equipment** to review the current group. The page shows each visible member, average item level, last known item in each tracked slot, and pulsing indicators for missing items, required enchants, empty sockets, or a missing limited gem.

**Enable Auto Refresh** is off by default and is stored as `lootHelper.raidCheckAuditAutoRefresh`. It does not require a profile. Use **Refresh Snapshot** for a short manual inspect pass. Background inspection runs only while this page is open and auto refresh or a manual refresh window is active.

Equipment observations are runtime-only. `/reload` clears them. Older SavedVariables equipment snapshots, if present, stay on disk and are not used.

## Session prompt

When you run Pre-Raid Check or Raid Check:

- If a Loot Helper session is already active for the selected profile, the check starts immediately.
- If a session is active for a **different** profile, the check still runs against the selected profile. A warning explains that consequences stay local to that profile and will not synchronize through the unrelated session. The addon does not switch profiles or end the other session.
- If no session is active, a prompt appears:
  - **Yes** starts a Loot Helper session for the selected profile, then starts the check only if session startup succeeds.
  - **No** runs the check without a session.
  - **Escape / close / Cancel** aborts. Nothing is inspected and no session is started.

Explicit No is the only no-session path. Duplicate clicks do not open a second prompt or start a second run.

## Combat

If the check starts in combat, targets and the selected profile still freeze, then inspection pauses until combat ends. If combat starts mid-run, completed results are kept and remaining targets resume afterward. Time spent paused does not consume the inspect time budget. Manual Blizzard Inspect is treated the same way: a temporary system pause, not Unprepared.

## Who is evaluated

At run start the addon freezes:

- the selected profile and its consequence settings;
- the target set = that profile's members who are currently in the group.

Someone who joins after freeze is ignored. Someone who leaves stays in the run and is classified from accumulated inspect evidence. Changing the selected profile mid-run does not redirect the check.

## Results

**Pre-Raid Check** reports results. It does not award points, Attendance, or Reward Pot changes.

**Raid Check** additionally:

- awards configured loot points in Point Based mode, or `1` Attendance in Reward Pot mode, to **Prepared** members;
- deducts from the Reward Pot once if any evaluated member is **Unprepared** (policy or never inspectable). **Inspection Failed** does not deduct.

### Recently Verified

If a player cannot be refreshed only because they are out of range, and a complete runtime observation from this session is at most about 120 seconds old, the check may treat them as **Recently Verified** using that last-good result. A technical inspect failure in this run is not replaced by that fallback.

### Inspection Failed

Inspection Failed means Spectrum attempted to inspect the player and the data was incomplete or the inspect timed out. It is reported separately to the admin. It does **not**:

- award Prepared credit;
- count as Unprepared for the Reward Pot;
- send a missing-equipment whisper.

A later out-of-range state does not rewrite Inspection Failed into Unprepared.

## Whispers

Whispers are disabled by default and are configured on **Loot Helper → Session**. They do not control the admin system-message summary.

Templates support `{player_name}`, `{missing}`, `{point_name}`, and `{points_awarded}`. Missing-requirement whispers are suppressed for the same check type on the same calendar day. Inspection Failed does not send a missing-gear whisper.

## What gets recorded

Point Based awards are loot-point log entries with **Raid Check** as the author. Reward Pot awards are Attendance log entries with the same author. A Reward Pot deduction is a Reward Pot change with **Raid Check** as the author. If there is no matching announced session, those logs are saved locally and are not synchronized.

Run checks from **Loot Helper → Session**, or use `/sf raidcheck pre` and `/sf raidcheck raid`.

Running Raid Check more than once can award points or Attendance again and, in Reward Pot mode, deduct from the pot again.
