# Loot Logs

Loot Logs are the audit history for the active loot profile. They are also the source used to rebuild member loot-point and Attendance balances, equipment-category state, Reward Pot totals, and to synchronize changes between clients.

Open **Loot Logs** in the Spectrum Federation settings window.

## What is recorded

The log includes:

- profile creation and renames;
- loot-point increases and decreases, including Raid Check awards;
- Attendance increases and decreases, including Raid Check awards;
- Raid Check presence snapshots used for the roster attendance and preparedness percentages;
- loot-mode changes;
- Reward Pot starting amount and deduction settings;
- Reward Pot gold added, subtracted, or deducted by Raid Check;
- equipment categories marked used or available;
- member role changes;
- point-name changes;
- raid-wide safe-mode changes;
- admins added or removed;
- character links and unlinks;
- historical Main Swap consolidations;
- persistent specialization changes;
- automatic BiS results that need attention (assigned, overflow, or unresolved). These rows use the RC Loot Council type. A frozen not-BiS result is kept for reconstruction and omitted from this list;
- Gear Override assign, clear, replace, and legacy association;
- manual loot additions and reversals;
- RC Loot Council awards, when the optional integration child addon is enabled and an active Spectrum session records them;
- bonus rolls that RC Loot Council reports in its history. Those rows are Bonus Roll, not RC Loot Council awards.

Each row shows the date, change type, affected member when applicable, a readable action, and the author.

RC Loot Council rows use the loot recipient as the member, `[Item Link] (Response)` as the action (hover the link for the item tooltip), and the RC master looter as the author. The original RC response label is stored with the entry. These rows use an external identity and do not participate in the ordinary sequential author-and-counter repair ranges. Several admins can observe the same award; Spectrum keeps one RC row. The session coordinator writes one automatic BiS outcome for that award. If the outcome is not BiS, it is stored and hidden here.

Assigned, overflow, and unresolved BiS results stay in that same RC Loot Council category and use its color. There is no separate BiS Outcome category. The action text still says whether the result was assigned, overflow, or unresolved. The Author column shows the master looter from the source RC award when that award can be resolved. If it cannot, the column shows the Spectrum officer who stored the outcome. The stored author on the BiS row remains that officer.

Bonus Roll rows use the recipient as the member and the item link as the action. They use their own external identity, so several observers still produce one row, and they do not create an RC Loot Council row or a BiS outcome.

Reward Pot amounts appear as gold, silver, and copper. A percent Raid Check deduction is stored as the gold amount calculated when the check ran.

## Filter the history

Use the controls above the table to filter by:

- change type;
- author;
- affected member.

The change-type list has one **RC Loot Council** option. Choosing it shows RC awards together with visible BiS results (assigned, overflow, and unresolved). It does not show Bonus Roll, and it does not offer a separate BiS Outcome type. The author filter matches the Author column, including a BiS row that displays its source RC awarder.

Filters apply together. Select **Clear** to return to the complete history. The newest matching entries appear first.

## Why logs are append-only

Corrections create new entries instead of modifying old ones. This preserves the audit trail and lets clients identify and request missing ranges reliably.

Member loot-point, Attendance, equipment, loot-mode, and Reward Pot state is derived by replaying the relevant entries. Profile synchronization deduplicates entries by their stable author-and-counter ID.

## Debug logs are different

Loot Logs are durable profile data. The **Debugging** page contains diagnostic messages about addon operation and is stored separately. Clearing debug logs does not alter Loot Helper history.
