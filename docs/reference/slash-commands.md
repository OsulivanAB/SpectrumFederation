# Slash Command Reference

The dispatcher lowercases the entire command line. Commands are therefore case-insensitive, but profile-name arguments are also lowercased before lookup. Use a profile ID when a profile's displayed name contains capital letters.

## Settings and help

| Command | Result |
| --- | --- |
| `/sf` | Toggle the standalone settings window. |
| `/sf help` | Print all registered commands and short descriptions. |

## Profile commands

| Command | Result |
| --- | --- |
| `/sf profiles` | List local loot profiles, their IDs, and the active profile. |
| `/sf activeprofile` | Show metadata and member/log counts for the active profile. |
| `/sf createprofile <name>` | Create a profile and make it active. |
| `/sf switchprofile <name-or-id>` | Select a profile by exact name or stable ID. |
| `/sf deleteprofile <name-or-id>` | Delete a local profile. If it was active, clear the active selection. |

Profile names may contain spaces. Profiles created by slash command receive a lowercase name because of command normalization.

## Loot Helper and sync

| Command | Result |
| --- | --- |
| `/sf loot` | Enable Loot Helper if needed and re-evaluate roster-window visibility. |
| `/sf loot session start` | Start a sync session for the active profile. Requires a party or raid and profile-admin permission. |
| `/sf loot session end` | End the active session. Only its coordinator can end it explicitly. |
| `/sf loot sync` | Ask the current coordinator to compare and catch up this client. Not available to the coordinator. |

Any other text after `/sf loot` currently performs the same default action as `/sf loot`; it does not produce a subcommand error.

## Raid Check

| Command | Aliases | Result |
| --- | --- | --- |
| `/sf raidcheck pre` | `pre-raid`, `preraid` | Run a non-awarding preparation check. |
| `/sf raidcheck raid` | `start`, no argument | Run the awarding Raid Check. |

Both modes require an active profile and profile-admin permission. Entering another argument prints the supported syntax.

## Addon versions

| Command | Result |
| --- | --- |
| `/sf version` | Open a resizable window listing current raid or party members and the Spectrum Federation version each one is running. Players who do not respond receive a red X. |

The window remembers its size and position, and it can be closed with the title-bar X. Use the command again to refresh the list. Solo players see only themselves.

## Debugging

| Command | Aliases | Result |
| --- | --- | --- |
| `/sf debug on` | `enable` | Enable diagnostic logging. |
| `/sf debug off` | `disable` | Disable diagnostic logging. |
| `/sf debug show` | `logs`, no argument | Open the Debugging page. |
| `/sf debug clear` | — | Remove all diagnostic entries. |

Debug logs are not Loot Logs and clearing them does not change profile history.

## Sync diagnostics

`/sflhsync` and `/lhsync` are equivalent low-level diagnostic commands. They are not listed by `/sf help`.

| Command | Result |
| --- | --- |
| `/sflhsync` | Print the current sync/session status. |
| `/sflhsync status` | Print the same status summary. |
| `/sflhsync requests` | List outstanding sync requests. Alias: `req`. |
| `/sflhsync metrics [text]` | Print sync counters, gauges, and statistics, optionally filtered by text. |
| `/sflhsync help` | Print the diagnostic command list. Alias: `?`. |

These commands inspect state; they do not start, stop, or repair a session.

## Unknown commands

An unknown top-level command prints an error and points to `/sf help`. Command execution is protected so a handler error is reported instead of stopping the entire slash-command dispatcher.
