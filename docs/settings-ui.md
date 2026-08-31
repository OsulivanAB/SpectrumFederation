# Settings

Enter `/sf` to toggle Spectrum Federation's standalone settings window. Changes are saved immediately; there is no Apply button.

The left sidebar lists **categories** grouped as Core, Loot Tools, Advanced, and Optional. Categories with more than one page show **tabs** in the content area. Categories with a single page have no tab bar. The first `/sf` open in a session starts on **General**. Later `/sf` toggles restore the category and tab from this session; that restoration is not saved across a reload.

**Quick Find** matches category and page names, descriptions, and group labels. With a search query, choosing a category opens the best matching page in that category.

Installed optional child addons appear under **Optional**. If the add-on is enabled for this character but has no settings pages yet, the category opens to a generic empty state. If an optional add-on is disabled for this character, the row stays visible and greyed; hover explains that it must be enabled in World of Warcraft's AddOns list. Spectrum Federation cannot enable or disable child addons from `/sf`.

`Enable LootHelper` on the Loot Helper General tab only shows or hides the roster window. It does not grey the Loot Helper category.

The window can be resized from the bottom-right grip. Wide pages such as Equipment and Loot Logs raise the minimum size when needed, but leaving those pages does not shrink the window.

## General

**Window Style**

Choose **Default**, **Compact**, or **Minimal** for the Loot Helper window.

**Font Style**

Choose **Friz Quadrata**, **Arial Narrow**, or **Morpheus** for the Loot Helper title and roster.

**Font Size**

Set Loot Helper title and roster text between 8 and 20 points.

These appearance settings do not currently restyle the standalone settings window or every addon surface.

## Gameplay: UI Enhancements

The **Gameplay** category opens a single **UI Enhancements** page. That page is character-specific: each character stores its own Mouse Tracer settings.

### Mouse Tracer

Mouse Tracer can leave a fading circular rainbow trail behind the mouse cursor. It is off by default.

- **Enable Mouse Tracer** — show or hide the trail on this character. When this is off, the trail is removed immediately and Mouse Tracer does no continuous work.
- **Trail Length** — how far the trail can extend behind the cursor.
- **Fade Duration** — how quickly the trail disappears after the cursor stops.
- **Trail Thickness** — visual width of the trail.
- **Rainbow Cycle Speed** — how quickly rainbow colors travel along the trail. This does not change how long the trail is.
- **Trail Opacity** — overall visibility. Lower values keep more of the UI readable underneath.
- **Copy From Character** — replace this character's Mouse Tracer settings with another character's last saved settings. The other character must have logged in with Spectrum Federation so a snapshot exists. The current character is not listed. Copy cannot be undone except by copying back or changing the controls again.

The sliders update the visible trail while you drag them. Copy overwrites every Mouse Tracer setting on this character, including whether the trail is enabled.

## Loot Helper: General

- **Enable LootHelper** — show or hide the roster window when its other visibility conditions are met. Sync and Raid Check still initialize and remain available.
- **Lock Loot Window** — prevent moving and resizing the Loot Helper window.
- **Show Members not in raid** — include profile members who are absent from the current raid.
- **Show Loot Window outside of Raid** — allow the roster window while solo or in a party.
- **Enable Local Safemode** — save the intended local safe-mode preference.
- **Enable Local Safemode on Combat** — save the intended combat preference.
- **Reset All LootHelper Settings** — delete every local profile and clear the active profile selection.

The two local safe-mode controls are not currently connected to the synchronization runtime and do not pause transfers. The reset action is destructive and requires confirmation; despite its label, it does not restore every Loot Helper option.

## Loot Helper: Profile

This page selects and manages the active profile. It includes:

- profile creation, selection, rename, reset, and deletion;
- profile owner and point-name display;
- owner-only loot mode: Point Based or Reward Pot;
- Reward Pot starting amount, Raid Check deduction, and gold add/subtract controls when Reward Pot is active;
- Raid Check point, gem, meta-gem, and enchant requirements.

Rename and profile-specific configuration are admin-only. Only the profile owner can change loot mode. Creating a profile makes the creator its owner and first admin.

**Reset Current Profile** is currently a nonfunctional placeholder and reports that it is not implemented.

## Loot Helper: Session

This page includes:

- start/end session control;
- saved raid-wide safe-mode preferences for all-the-time or combat use;
- Pre-Raid Check and Raid Check actions;
- admin system-message summaries of missing players, independent of whisper settings;
- optional whispers for missing and prepared players;
- editable whisper templates.

The two raid-wide safe-mode preferences are not currently connected to the runtime session safe-mode API. They persist on the profile but do not pause session transfers.

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
