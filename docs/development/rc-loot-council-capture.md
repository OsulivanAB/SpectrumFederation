# RC Loot Council Capture

This temporary child addon records RC Loot Council addon communications while a Spectrum Loot Helper session is active. It is diagnostic tooling, not production RC integration.

The child addon lives in `SpectrumFederation_RCLootCouncilCapture/`. It does not interpret RC commands into Spectrum loot actions, write Loot Logs, award points, or send RC messages.

## What it captures

The logger registers its own AceComm receiver for the current RC prefixes `RCLC`, `RCLCv`, and `RCLCs`. It stores the reassembled logical payload delivered to this client, then attempts a best-effort decode that mirrors current RCLootCouncil2:

1. LibDeflate `DecodeForWoWAddonChannel`
2. LibDeflate `DecompressDeflate`
3. AceSerializer deserialize to `command` + `data`
4. Preserve `xrealm` envelope fields and derived command/target data

Locally sent RC messages are not recorded. WoW does not echo a sender's own RAID/PARTY/INSTANCE addon traffic back through `CHAT_MSG_ADDON`, and this addon does not hook `SendAddonMessage` or RC internals.

## SavedVariables

Account-wide data is stored in `SpectrumFederationRCLootCouncilCaptureDB` and written by WoW to:

`WTF/Account/<account>/SavedVariables/SpectrumFederation_RCLootCouncilCapture.lua`

The in-memory table is the authoritative log. `/reload` or logout serializes it to disk.

## Settings

Open `/sf` → **Loot Helper → RC Loot Council**. The page shows live status and the most recent 250 persisted entries. There is no clear/reset control.

## Removal

1. Preserve or upload the SavedVariables file first.
2. Delete `SpectrumFederation_RCLootCouncilCapture/`.
3. Remove the child-addon registrations from packaging, version, lint, workflow, docs, and test files listed at the top of `Capture.lua`.
4. Optionally delete the user's SavedVariables file after analysis.
