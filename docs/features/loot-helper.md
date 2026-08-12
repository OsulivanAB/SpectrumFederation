# Loot Helper

Loot Helper is the addon's main raid roster and point-management window. It combines the active profile's members with the current raid roster so admins can make routine loot decisions without editing profile data by hand.

## When the window appears

Loot Helper requires the feature to be enabled and an active profile to exist. By default, its window is shown only while you are in a raid. **Show Loot Window outside of Raid** removes the raid-only restriction.

Enter `/sf loot` to enable Loot Helper and re-evaluate the window. The title bar also provides:

- a play/stop button for sync sessions, visible to profile admins;
- a settings button that opens the Loot Helper settings;
- a minimize button;
- drag and resize behavior, unless **Lock Loot Window** is enabled.

The window's position, size, and minimized state are saved locally.

## Understanding the roster

Profile members show their class or specialization icon, class-colored name, current point balance, and equipment-history button.

When you are in a raid, the window also identifies raid members who are not in the active profile. An admin can add them with the plus button. The **Show Members not in raid** setting controls whether absent profile members remain visible.

## Admin actions

Profile admins can:

- increase or decrease points in half-point steps;
- add current raid members to the profile;
- mark equipment categories used or available;
- create, select, rename, and delete profiles;
- change the profile's point name;
- add or remove admins;
- transfer one character's point and equipment history to another with **Main Swap**;
- configure and run Raid Checks;
- start sync sessions and, when acting as coordinator, end them.

Non-admins can view the roster, points, equipment history, logs, and synchronized profile data. Shared-data controls such as point/equipment changes, profile settings, Raid Check, sessions, and admin management are hidden or disabled in the UI.

Creating, selecting, and deleting a local profile copy are available without profile-admin status. Those local actions are distinct from authorization to write shared profile history during synchronization.

## Equipment-category history

Select the equipment button on a member row to open the equipment window. It tracks these loot categories:

- head, neck, shoulders, back, chest, wrists, hands, belt, legs, and boots;
- weapon and off-hand;
- two ring uses and two trinket uses.

This is profile history, not a live inspection of equipped items. Admins toggle a category when the member uses or regains that loot opportunity. Toggling a category also adjusts the member's points and creates a log entry.

The separate [Raid Check](raid-check.md) equipment page inspects current gear for enchants and gems.

## Profiles

Only one profile is active locally at a time. Creating or selecting a profile makes it the source for the roster, session, Raid Check, and Loot Logs pages.

A profile includes:

- a stable ID and editable display name;
- an owner, admins, and members;
- a customizable point name and point balances;
- equipment-category state;
- Raid Check requirements and saved equipment snapshots;
- raid-wide safe-mode preferences;
- append-only change logs.

Deleting a profile removes it from this client. During an active sync session, other clients may still retain their copy.

The current **Reset Current Profile** action is a placeholder and does not reset profile settings. **Reset All LootHelper Settings** deletes local profiles and clears the active selection; it does not restore every general Loot Helper option.

## Main Swap

**Transfer Points / Main Swap** consolidates an old profile character into another existing profile member. It rewrites relevant point and equipment history to the target, removes the source member, and records the operation in Loot Logs.

Both source and target must already be profile members. Review the selected names carefully; this is an admin-only data migration, not a temporary display preference.

## Related pages

- [Raid Check](raid-check.md)
- [Sync Sessions](sync-sessions.md)
- [Loot Logs](loot-logs.md)
- [Settings and Gameplay](../settings-ui.md)
