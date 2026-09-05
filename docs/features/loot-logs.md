# Loot Logs

Loot Logs are the audit history for the active loot profile. They are also the source used to rebuild member loot-point and Attendance balances, equipment-category state, Reward Pot totals, and to synchronize changes between clients.

Open **Loot Logs** in the Spectrum Federation settings window.

## What is recorded

The log includes:

- profile creation and renames;
- loot-point increases and decreases, including Raid Check awards;
- Attendance increases and decreases, including Raid Check awards;
- loot-mode changes;
- Reward Pot starting amount and deduction settings;
- Reward Pot gold added, subtracted, or deducted by Raid Check;
- equipment categories marked used or available;
- member role changes;
- point-name changes;
- raid-wide safe-mode changes;
- admins added or removed;
- Main Swap consolidations;
- RC Loot Council awards, when the optional integration child addon is enabled and an active Spectrum session records them.

Each row shows the date, change type, affected member when applicable, a readable action, and the author.

RC Loot Council rows use the loot recipient as the member, the awarded item link as the action (hover the link for the item tooltip), and the RC master looter as the author. The original RC response label is stored with the entry. These rows use an external identity and do not participate in the ordinary sequential author-and-counter repair ranges.

Reward Pot amounts appear as gold, silver, and copper. A percent Raid Check deduction is stored as the gold amount calculated when the check ran.

## Filter the history

Use the controls above the table to filter by:

- change type;
- author;
- affected member.

Filters apply together. Select **Clear** to return to the complete history. The newest matching entries appear first.

## Why logs are append-only

Corrections create new entries instead of modifying old ones. This preserves the audit trail and lets clients identify and request missing ranges reliably.

Member loot-point, Attendance, equipment, loot-mode, and Reward Pot state is derived by replaying the relevant entries. Profile synchronization deduplicates entries by their stable author-and-counter ID.

## Debug logs are different

Loot Logs are durable profile data. The **Debugging** page contains diagnostic messages about addon operation and is stored separately. Clearing debug logs does not alter Loot Helper history.
