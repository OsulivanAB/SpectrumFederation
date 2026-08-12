# Settings and Gameplay

Enter `/sf` to toggle Spectrum Federation's standalone settings window. Changes are saved immediately; there is no Apply button.

## General

**Window Style**

Choose **Default**, **Compact**, or **Minimal** for supported Spectrum Federation windows.

**Font Style**

Choose **Friz Quadrata**, **Arial Narrow**, or **Morpheus**.

**Font Size**

Set addon text between 8 and 20 points.

## Gameplay

### Press and Hold Casting

The Gameplay page lists every specialization for the current character. Enable a specialization to turn WoW's Press and Hold Casting CVar on automatically while that specialization is active; disable it to turn the CVar off.

This preference is saved per character and per specialization. The addon:

- initializes missing specialization choices from the character's current CVar;
- reapplies the selected value after login or UI reload;
- reapplies it when the active specialization changes;
- defers the CVar update until combat ends when necessary.

Because this controls a shared WoW CVar, changing it elsewhere may be overwritten the next time Spectrum Federation reapplies the selected specialization preference.

## Loot Helper: General

- **Enable LootHelper** — enable or disable the roster window and related local behavior.
- **Lock Loot Window** — prevent moving and resizing the Loot Helper window.
- **Show Members not in raid** — include profile members who are absent from the current raid.
- **Show Loot Window outside of Raid** — allow the roster window while solo or in a party.
- **Enable Local Safemode** — pause bulk sync and profile transfers on this client.
- **Enable Local Safemode on Combat** — turn local safe mode on when combat begins during an active session.
- **Reset All LootHelper Settings** — delete every local profile and restore Loot Helper defaults.

The reset action is destructive and requires confirmation.

## Loot Helper: Profile

This page selects and manages the active profile. It includes:

- profile creation, selection, rename, reset, and deletion;
- profile owner and point-name display;
- Raid Check point, gem, meta-gem, and enchant requirements.

Rename and profile-specific configuration are admin-only. Creating a profile makes the creator its owner and first admin.

## Loot Helper: Session

This page includes:

- start/end session control;
- saved raid-wide safe-mode preferences for all-the-time or combat use;
- Pre-Raid Check and Raid Check actions;
- optional whispers for missing and prepared players;
- editable whisper templates.

The two raid-wide safe-mode preferences are not currently connected to the runtime session safe-mode API. They persist on the profile but do not pause session transfers. Local safe mode remains functional.

The visible **Trigger Raid-Wide Sync** control is currently a placeholder. It does not initiate a sync; use `/sf loot sync` on the client that needs to catch up.

## Loot Helper: Equipment

The Equipment page displays the current Raid Check inspection snapshot. Auto refresh is off by default; enable it or select **Refresh Snapshot** when you need current data.

See [Raid Check](features/raid-check.md) for interpretation and inspection limitations.

## Loot Helper: Admin

Profile admins can add profile members as admins, remove admins other than the owner, and run **Transfer Points / Main Swap**.

The owner cannot be removed from the admin list through this page.

## Loot Logs

Filter the active profile's history by event type, author, or member. These filters are temporary UI state and are not saved.

## Debugging

Start or stop diagnostic logging, filter the viewer by level, copy log text, or clear the diagnostic log. Debug data is separate from Loot Logs.

Use debugging while investigating a problem; verbose logs can be noisy. The database retains at most 500 diagnostic entries.

## For contributors

Implementation and extension guidance lives in [Settings System](development/settings-ui/index.md).
