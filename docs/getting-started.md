# Getting Started

## Install the addon

Install **Spectrum Federation** with the CurseForge client, WowUp, or a release archive from [GitHub Releases](https://github.com/OsulivanAB/SpectrumFederation/releases).

For a manual installation, extract the archive and place **both** `SpectrumFederation` and `SpectrumFederation_CursedSurgeTracker` folders in the Retail AddOns directory:

- Windows: `World of Warcraft\_retail_\Interface\AddOns\`
- macOS: `World of Warcraft/_retail_/Interface/AddOns/`

Restart World of Warcraft or run `/reload`, then enable the addon for the characters that will use it.

## Open Spectrum Federation

Enter `/sf` to toggle the addon's standalone settings window. The navigation is grouped into:

- **Core** — appearance and character-specific gameplay automation.
- **Loot Tools** — Loot Helper configuration, profiles, sessions, equipment auditing, and logs.
- **Advanced** — diagnostic logging.

The Loot Helper window appears automatically when all of these conditions are true:

1. Loot Helper is enabled.
2. An active profile is selected.
3. You are in a raid, unless **Show Loot Window outside of Raid** is enabled.

You can also enter `/sf loot` to enable Loot Helper and ask it to show the window.

## Create your first loot profile

1. Open `/sf`.
2. Select **Loot Helper → Profile**.
3. Enter a name under **Create Profile** and select **Create**.

The new profile becomes active immediately. Its creator is added as the owner, first member, and first admin.

Profiles hold their own roster, loot mode, point name, Attendance, Reward Pot, admin list, Raid Check configuration, safe-mode options, equipment snapshots, and change history. Switching profiles changes the data shown by Loot Helper and Loot Logs.

## Add and manage members

Join a raid with the people you want to add. In the Loot Helper roster, players who are in the raid but not yet in the active profile have an add button for profile admins.

For profile members:

- In Point Based mode, the up and down buttons adjust the member's loot-point balance in half-point steps.
- In Reward Pot mode, those buttons adjust Attendance by one, and the current pot is shown above the list.
- The equipment button opens that member's equipment-category history.
- Admins can mark equipment categories used or available; all users can view them.

Enable **Show Members not in raid** if you want the roster to include offline or absent profile members.

The profile owner can switch loot mode under **Loot Helper → Profile**. See [Point Based](features/point-based.md) and [Reward Pot](features/reward-pot.md).

## Start a shared session

A profile admin who is in a party or raid can start a session from:

- the play button in the Loot Helper title bar;
- **Loot Helper → Session → Session Control**; or
- `/sf loot session start`.

The coordinator compares profile history with other online admins, then announces the session. Other addon users automatically request a profile or missing history when needed. See [Sync Sessions](features/sync-sessions.md) for safe modes and session behavior.

## Run a Raid Check

Profile admins can configure requirements under **Loot Helper → Profile**, then run:

- **Pre-Raid Check** to report preparation problems without awarding points, Attendance, or pot changes.
- **Raid Check** to report problems and award loot points in Point Based mode, or Attendance and a possible pot deduction in Reward Pot mode.

See [Raid Check](features/raid-check.md) before enabling automatic whispers or awards.

## Useful commands

- `/sf` — toggle settings.
- `/sf help` — list registered commands.
- `/sf profiles` — list local profiles.
- `/sf raidcheck pre` — run a pre-raid check.
- `/sf raidcheck raid` — run the awarding raid check.
- `/sf version` — show who in the raid or party is running Spectrum Federation, and which version.
- `/sf loot sync` — manually compare your data with the active session.
- `/sfcst` — dump Cursed Surge Tracker diagnostics.

The [Slash Command Reference](reference/slash-commands.md) lists every supported command and restriction.
