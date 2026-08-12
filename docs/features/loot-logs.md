# Loot Logs

Loot Logs are the audit history for the active loot profile. They are also the source used to rebuild member point balances and equipment-category state and to synchronize changes between clients.

Open **Loot Logs** in the Spectrum Federation settings window.

## What is recorded

The log includes:

- profile creation and renames;
- point increases and decreases, including Raid Check awards;
- equipment categories marked used or available;
- member role changes;
- point-name changes;
- raid-wide safe-mode changes;
- admins added or removed;
- Main Swap consolidations.

Each row shows the date, change type, affected member when applicable, a readable action, and the author.

## Filter the history

Use the controls above the table to filter by:

- change type;
- author;
- affected member.

Filters apply together. Select **Clear** to return to the complete history. The newest matching entries appear first.

## Why logs are append-only

Corrections create new entries instead of modifying old ones. This preserves the audit trail and lets clients identify and request missing ranges reliably.

Member point and equipment state is derived by replaying the relevant entries. Profile synchronization deduplicates entries by their stable author-and-counter ID.

## Debug logs are different

Loot Logs are durable profile data. The **Debugging** page contains diagnostic messages about addon operation and is stored separately. Clearing debug logs does not alter Loot Helper history.
