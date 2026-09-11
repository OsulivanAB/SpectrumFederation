# Loot Helper

Loot Helper is the addon's main raid roster window. It combines the active profile's members with the current raid roster so admins can make routine loot decisions without editing profile data by hand.

Each profile uses one loot mode: [Point Based](point-based.md) or [Reward Pot](reward-pot.md). Point Based is the default. The owner of the profile chooses the mode.

## When the window appears

Loot Helper requires the feature to be enabled and an active profile to exist. By default, its window is shown only while you are in a raid. **Show Loot Window outside of Raid** removes the raid-only restriction.

Enter `/sf loot` to enable Loot Helper and re-evaluate the window. The title bar also provides:

- a play/stop button for sync sessions, visible to profile admins;
- a settings button that opens the Loot Helper settings;
- a minimize button;
- drag and resize behavior, unless **Lock Loot Window** is enabled.

The window's position, size, and minimized state are saved locally. Minimizing and restoring keep the title bar in place so the window grows and shrinks downward.

## Understanding the roster

Profile members show their class or specialization icon, class-colored name, a mode-specific total, and an equipment-history button.

- In **Point Based**, the title uses the profile's point name and each row shows loot points.
- In **Reward Pot**, the title shows Attendance, each row shows Attendance, and the current Reward Pot appears above the list.

When you are in a raid, the window also identifies raid members who are not in the active profile. An admin can add them with the plus button. The **Show Members not in raid** setting controls whether absent profile members remain visible.

Linked characters remain separate rows. When both are visible, identity-wide totals match while character-specific history stays distinct.

## Admin actions

Profile admins can:

- increase or decrease loot points in half-point steps in Point Based, or Attendance by one in Reward Pot;
- add current raid members to the profile;
- mark equipment categories used or available;
- create, select, rename, and delete profiles;
- change the profile's point name in Point Based;
- add or subtract Reward Pot gold and configure the pot in Reward Pot;
- add or remove admins;
- link characters so they share identity-wide points, Attendance, and equipment opportunity state;
- configure and run Raid Checks;
- start sync sessions and, when acting as coordinator, end them;
- set a character's persistent spec and correct item-aware BiS assignments from **Loot Helper → Character**.

Only the profile owner can change loot mode.

Non-admins can view the roster, totals, the Reward Pot amount, equipment history, logs, and synchronized profile data. Shared-data controls such as point, Attendance, pot, and equipment changes, profile settings, Raid Check, sessions, and admin management are hidden or disabled in the UI.

Creating, selecting, and deleting a local profile copy are available without profile-admin status. Those local actions are distinct from authorization to write shared profile history during synchronization.

## Preview as Non-Admin

Canonical admins of the active profile can preview that profile as a non-admin on this client only. Enable it from **Loot Helper → Admin → Preview as Non-Admin** or `/sf impersonate on`.

The preview:

- never grants admin or owner privileges;
- does not change your real profile role, admin list, or sync identity;
- is not saved; `/reload` ends it;
- ends immediately if you switch, clear, delete, or reset the active profile, including **Reset All LootHelper Settings**. Switching back does not turn it back on.

While it is active, a red banner appears on every Settings page, local admin/owner controls behave as they do for a genuine non-admin, and other clients still treat you as your real role. Use the same Settings toggle or `/sf impersonate off` to return to your real local permissions.

## Equipment-category history

Select the equipment button on a member row to open the equipment window. It tracks these loot categories:

- head, neck, shoulders, back, chest, wrists, hands, belt, legs, and boots;
- weapon and off-hand;
- two ring uses and two trinket uses.

This is profile history, not a live inspection of currently equipped items.

When the profile has BiS-qualifying RC responses configured **and** `Record RC Loot Council awards` is on, or any item-aware BiS history (`BIS_OUTCOME`, `BIS_OVERRIDE`, `MANUAL_AWARD`, `MANUAL_AWARD_REVERSE`), the popup is **item-aware**: it shows assigned item icons and tooltips, including legacy unknown consumptions. Admins do not click-to-toggle in that mode. Corrections happen in **Loot Helper → Character** (Gear Override). Saved BiS-response configuration is kept while recording is off, but it does not make the popup item-aware by itself.

When recording is off and there is no item-aware history, or when there is no BiS configuration, the popup keeps generic equipment icons and the existing admin click-to-toggle behavior, including identity-wide occupancy from linked characters. The core popup works without the RC Loot Council Integration child addon.

Toggling in manual mode creates an equipment-history log entry and does not change loot points or Attendance.

Linked characters share the projected equipment opportunity state. Unmarked historical equipment changes stay character-local and are aggregated after reconstruction. New shared corrections record the linked membership at write time. They stay active while those original members remain together, including when other characters join or leave. If any original member is split from the others, that correction expires permanently and does not return if the same characters are linked again. A later correction on a newly expanded identity replaces earlier overlapping subset-scope state for that slot. Independent identities that later merge still combine their equipment histories: two scoped ring or trinket uses fill the two shared opportunities before overflowing.

Manual Ring 1 / Ring 2 and Trinket 1 / Trinket 2 clicks target the displayed slot. An empty Ring 1 is not filled automatically by a Ring 2 click. Frozen automatic BiS overflow never fills a later hole; Gear Override can assign that loot explicitly.

**Loot Helper → Character** uses a character-equipment layout: empty slots show placeholders, used slots show the item icon (WoW tooltip plus a red X to clear), and clicking a slot offers only loot that fits that slot. An already-assigned item can be selected on another empty compatible slot and moved with one atomic `REPLACE`. Admins can also assign unused RC or manual loot, replace an occupying assignment, or associate unused loot with a still-active `#278` unknown-usage origin (`LEGACY_UNKNOWN`, gold glow). Overflow ring/trinket `#278` origins stay in provenance for conflict accounting and are not associable displayed opportunities. The selected character's spec editor stays on the same page. Assignments always use the award owner's stored spec, class weapon-subclass proficiency (fail closed on unknown IDs), and the linked identity's native Ring/Trinket packing scope. Automatic `BIS_OUTCOME ASSIGNED` rows replay the frozen award-time slots; current live classifier or proficiency tables do not reinterpret them. A local Gear Override write is rejected if Replay occupancy, including `#278`, would make it a no-op.

The separate [Raid Check](raid-check.md) **Raid Equipment** page inspects current gear for enchants and gems.

## Profiles

Only one profile is active locally at a time. Creating or selecting a profile makes it the source for the roster, session, Raid Check, and Loot Logs pages.

A profile includes:

- a stable ID and editable display name;
- an owner, admins, and members;
- a loot mode, customizable point name, loot-point balances, and Attendance balances;
- Reward Pot starting amount and deduction settings;
- equipment-category state;
- Raid Check whisper/award settings and inert legacy equipment snapshots;
- raid-wide safe-mode preferences;
- append-only change logs.

Deleting a profile removes it from this client. During an active sync session, other clients may still retain their copy.

The current **Reset Current Profile** action is a placeholder and does not reset profile settings. **Reset All LootHelper Settings** deletes local profiles and clears the active selection; it does not restore every general Loot Helper option.

## Linked Characters

**Link Characters** joins two existing profile members into one identity. They keep separate roster rows and character-attributed history. Points, Attendance, and equipment opportunity state are projected across the current linked group.

Admins can:

- link two characters;
- add a character to an existing linked identity by linking it to any current member;
- see current linked groups;
- unlink a character.

There is no Main or Primary character, and linking does not copy or delete history. Only the effective owner may change the canonical owner's identity. Other admins may manage non-owner identities.

Unlinking asks for confirmation because shared points, Attendance, and equipment opportunity state stop being combined.

Singleton characters keep their local Ring1/Ring2 and Trinket1/Trinket2. Linked identities pack currently-active local ring and trinket usages in log order onto projected Slot 1, then Slot 2, then overflow. Manual identity-scoped clicks still target the displayed projected slot.

Historical **Main Swap** entries remain in Loot Logs as lineage. They are not offered as a live transfer action.

## Related pages

- [Point Based](point-based.md)
- [Reward Pot](reward-pot.md)
- [Raid Check](raid-check.md)
- [Sync Sessions](sync-sessions.md)
- [Loot Logs](loot-logs.md)
- [Settings](../settings-ui.md)
