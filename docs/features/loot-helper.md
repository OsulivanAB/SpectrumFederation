# Loot Helper

Loot Helper is the addon's main raid roster window. It combines the active profile's members with the current raid roster so admins can make routine loot decisions without editing profile data by hand.

Each profile uses one loot mode: [Point Based](point-based.md) or [Reward Pot](reward-pot.md). Point Based is the default. The owner of the profile chooses the mode.

## When the window appears

Loot Helper requires the feature to be enabled and an active profile to exist. By default, its window is shown only while you are in a raid. **Show Loot Window outside of Raid** removes the raid-only restriction.

Enable Loot Helper and window visibility are separate. Turning Enable off hides the window and keeps it from appearing automatically. Closing the window with X only hides the UI for this session; sessions, sync, heartbeat, Raid Check, and related features keep running.

Enter `/sf loot` to enable Loot Helper if needed and show the window. That command is an explicit Show: it reopens a window you closed and does not toggle a visible window off. **Loot Helper → General → Loot Window** also shows or hides the roster. Eligibility rules still apply, so Show will not appear outside a raid unless **Show Loot Window outside of Raid** is on, and it still requires an active profile.

The title bar provides:

- a close (X) button that hides the window for this session;
- a play/stop button for sync sessions, visible to profile admins;
- a settings button that opens the Loot Helper settings;
- a minimize button;
- drag and resize behavior, unless **Lock Loot Window** is enabled.

Close remains usable while the window is locked. Closing does not change the saved minimized or expanded state. A `/reload` or relog clears the hidden override and returns to automatic visibility.

The window's position, size, and minimized state are saved locally. Minimizing and restoring keep the title bar in place so the window grows and shrinks downward. The close/hidden preference is not saved.

The window can be resized narrower than its default width. As width decreases, the raider name truncates with an ellipsis first and never shorter than the class or spec icon plus about three characters. If the window is still too narrow, **BiS** hides, then **Prep.**, then **Att.** Those columns return in the opposite order as the window gets wider. The equipment button, the Points column in Point Based mode, the readiness indicator, and the title-bar Start/Stop, Settings, Minimize, and Close controls stay available. Profile text in the title may truncate so those controls stay usable. Which glance columns are hidden is not saved; it follows the current width. A saved width above the minimum opens at that width.

## Understanding the roster

Profile members show their class or specialization icon, class-colored name, glance columns, and an equipment-history button.

- In **Point Based**, the title uses the profile's point name and each row shows that named point balance in its own column.
- In **Reward Pot**, the title shows Attendance, the Points column is hidden, and the current Reward Pot appears above the list.
- **Att.** is raid-check presence as a percentage. A player is credited when they were in the group at the start of a Raid Check, whether or not their gear was prepared. Players with no recorded presence opportunities show `—`.
- **Prep.** is raid-check preparedness as a percentage. A player is credited only when they were present and classified Prepared by the same Raid Check equipment rules (verified enchants, gems, and minimum item level when that profile requirement is enabled). Attendance is still credited for being present. Inspection Failed and out-of-range-without-recent-verify do not count as prepared. Older presence logs that predate this field show `—` rather than inventing a 0% history.
- **BiS** is slots already used out of the player's possible BiS slots, using the same identity projection as the equipment popup.
- The readiness icon appears only when cached equipment is known to be missing a Raid Check requirement. Ready and unknown rows leave that space blank. Out of range does not by itself mean Not Ready. Hover a warning for the missing requirements.

When you are in a raid, the window also identifies raid members who are not in the active profile. An admin can add them with the plus button. The **Show Members not in raid** setting controls whether absent profile members remain visible.

Linked characters remain separate rows. When both are visible, identity-wide totals match while character-specific history stays distinct.

## Admin actions

Profile admins can:

- increase or decrease Attendance points and loot points from **Loot Helper → Character** (these are not the roster Att.% or Prep. columns);
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

When the profile has BiS-qualifying RC responses configured **and** `Record RC Loot Council awards` is on, or any item-aware BiS history (`BIS_OUTCOME`, `BIS_OVERRIDE`, `MANUAL_AWARD`, `MANUAL_AWARD_REVERSE`), the popup is **item-aware**: it shows assigned item icons and tooltips, including consumed opportunities whose item is unknown. An admin click opens **Loot Helper → Character** with that character and slot selected. It does not write an equipment toggle. Non-admins cannot use that correction path. Saved BiS-response configuration is kept while recording is off, but it does not make the popup item-aware by itself.

When recording is off and there is no item-aware history, or when there is no BiS configuration, the popup keeps generic equipment icons and the existing admin click-to-toggle behavior, including identity-wide occupancy from linked characters. The core popup works without the RC Loot Council Integration child addon.

Toggling in manual mode creates an equipment-history log entry and does not change loot points or Attendance.

Linked characters share the projected equipment opportunity state. Unmarked historical equipment changes stay character-local and are aggregated after reconstruction. New shared corrections record the linked membership at write time. They stay active while those original members remain together, including when other characters join or leave. If any original member is split from the others, that correction expires permanently and does not return if the same characters are linked again. A later correction on a newly expanded identity replaces earlier overlapping subset-scope state for that slot. Independent identities that later merge still combine their equipment histories: two scoped ring or trinket uses fill the two shared opportunities before overflowing.

Manual Ring 1 / Ring 2 and Trinket 1 / Trinket 2 clicks target the displayed slot. An empty Ring 1 is not filled automatically by a Ring 2 click. Frozen automatic BiS overflow never fills a later hole; Gear Override can assign that loot explicitly.

**Loot Helper → Character** uses a character-equipment layout: empty slots show placeholders, used slots show the item icon (WoW tooltip plus a red X to clear), and clicking a slot offers loot that fits that slot. Known raid tier tokens are classified by base item ID in core Spectrum, so the same token is recognized from RC Loot Council or from manually added loot. The Slumbering Coil Curio stays unresolved until an admin force-assigns it. Other unresolved awards can be force-assigned to the selected slot; that choice is stored on the Gear Override log and is not reinterpreted if a later version learns the item's slot. An already-assigned item can be selected on another empty compatible slot and moved with one atomic `REPLACE`. Local ASSIGN/REPLACE writers resolve the final slot set and refuse to append when Replay occupancy — including `#278` recorded equipment use under a BiS overlay — would make the correction a no-op. Admins can also assign unused RC or manual loot, replace an occupying assignment, mark an available slot **consumed — item unknown** (an `ARMOR_CHANGE`, not a fake item), or associate unused loot with a still-active unknown-consumption origin (`LEGACY_UNKNOWN`, gold glow, labeled "Consumed opportunity — item unknown"). When a packed origin has a projected `displayedSlot`, that displayed opportunity is the association target; the historical original slot is only a fallback when no displayed slot exists. Overflow ring/trinket `#278` origins stay in provenance for conflict accounting and are not associable displayed opportunities. The selected character's spec editor stays on the same page. Assignments always use the award owner's stored spec, class weapon-subclass proficiency, and spec combat-weapon subclass (fail closed on unknown IDs), and the linked identity's native Ring/Trinket packing scope. Automatic `BIS_OUTCOME ASSIGNED` rows replay frozen award-time classification and must describe the same source RC item; current live classifier or proficiency tables do not reinterpret them. A local Gear Override write is rejected if Replay occupancy, including `#278`, would make it a no-op.

The separate [Raid Check](raid-check.md) **Raid Equipment** page inspects current gear for enchants, gems, and the profile's minimum item level when that requirement is enabled. It still works with no active profile.

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
