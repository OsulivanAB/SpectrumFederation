# Google Sheet Sync

This guide explains how to keep a Google Sheet in sync with the active Loot Helper profile stored in `SpectrumFederation.lua`.

The sync flow is simple:

1. The Python utility watches the addon's `SavedVariables` file.
2. When the file changes, it parses the active loot profile.
3. It sends one full normalized payload to a Google Apps Script web app.
4. The Apps Script clears and rewrites the entire sheet, including formatting.

Because the sheet is fully rewritten on each update, manual edits in the sheet do not persist.

## Files You Need

The repo includes this runtime file:

- [Download spectrum_federation_sheet_sync.py](https://raw.githubusercontent.com/OsulivanAB/SpectrumFederation/beta/assets/spectrum_federation_sheet_sync.py): the standalone Python sync utility.

It also includes this optional convenience file:

- [Download spectrum_federation_sheet_sync.example.json](https://raw.githubusercontent.com/OsulivanAB/SpectrumFederation/beta/assets/spectrum_federation_sheet_sync.example.json): a starter config file you can rename to `spectrum_federation_sheet_sync.json`.

You can run the utility directly from this repo, or copy the `.py` file to any folder on your own machine.

## Requirements

- Python 3.10 or newer.
- A Google account.
- A Google Sheet you want to use for the synced roster.
- Access to the addon's `SpectrumFederation.lua` SavedVariables file.

## Step 1: Create the Google Sheet

1. Create a new Google Sheet.
2. Rename the target tab if you want something other than the default name.
3. Open `Extensions` -> `Apps Script`.
4. Replace the default script with the code below.
5. Edit the values inside the `CONFIG` object at the top.

### Apps Script Configuration

Edit these values before you deploy:

- `SHEET_NAME`: the tab name that will be rewritten on every sync.
- `SHARED_SECRET_PROPERTY_NAME`: the Script Property key that stores your secret value.
- `COLUMN_WIDTH`: fixed width to apply to every column on each sync.
- `FREEZE_HEADER_ROW`: set to `true` to keep the header row frozen.
- `AUTO_RESIZE_COLUMNS`: set to `true` if you want Google Sheets to resize columns after each update.

Do not hardcode your real shared secret in the Apps Script source. Store it in Apps Script Script Properties instead.

### Copy/Paste Apps Script Code

```javascript
const CONFIG = {
  SHEET_NAME: 'Spectrum Federation Sync',
  SHARED_SECRET_PROPERTY_NAME: 'SF_SHARED_SECRET',
  COLUMN_WIDTH: 100,
  FREEZE_HEADER_ROW: true,
  AUTO_RESIZE_COLUMNS: false,
  HEADER_BACKGROUND: '#434343',
  HEADER_FONT_COLOR: '#FFFFFF',
  PLAYER_BACKGROUND: '#434343',
  POINT_BACKGROUND: '#999999',
  POINT_FONT_COLOR: '#FFFFFF',
  ROW_STRIPE_ODD: '#efefef',
  ROW_STRIPE_EVEN: '#FFFFFF'
};

function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) {
      return jsonResponse_({ ok: false, error: 'Missing JSON body.' });
    }

    const requestBody = JSON.parse(e.postData.contents);
    const expectedSecret = getSharedSecret_();
    if (!requestBody || requestBody.secret !== expectedSecret) {
      return jsonResponse_({ ok: false, error: 'Shared secret mismatch.' });
    }

    const payload = requestBody.payload;
    validatePayload_(payload);

    const sheet = getOrCreateSheet_(CONFIG.SHEET_NAME);
    rewriteSheet_(sheet, payload);

    return jsonResponse_({
      ok: true,
      sheetName: CONFIG.SHEET_NAME,
      profileId: payload.profile.id,
      rowsWritten: payload.rows.length
    });
  } catch (error) {
    return jsonResponse_({ ok: false, error: error.message, stack: error.stack });
  }
}

function getSharedSecret_() {
  const secret = PropertiesService
    .getScriptProperties()
    .getProperty(CONFIG.SHARED_SECRET_PROPERTY_NAME);

  if (!secret) {
    throw new Error(
      'Missing Script Property ' + CONFIG.SHARED_SECRET_PROPERTY_NAME + '. ' +
      'Set it in Project Settings -> Script properties before deploying.'
    );
  }

  return secret;
}

function validatePayload_(payload) {
  if (!payload || typeof payload !== 'object') {
    throw new Error('Payload is missing.');
  }
  if (!Array.isArray(payload.headers) || payload.headers.length === 0) {
    throw new Error('Payload headers are missing.');
  }
  if (!Array.isArray(payload.rows)) {
    throw new Error('Payload rows are missing.');
  }
}

function getOrCreateSheet_(sheetName) {
  const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = spreadsheet.getSheetByName(sheetName);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(sheetName);
  }
  return sheet;
}

function rewriteSheet_(sheet, payload) {
  const headers = payload.headers;
  const columnCount = headers.length;
  const rowCount = payload.rows.length + 1;
  const values = [headers].concat(payload.rows.map((row) => row.cells));

  sheet.clear();
  sheet.getRange(1, 1, rowCount, columnCount).setValues(values);

  if (CONFIG.FREEZE_HEADER_ROW) {
    sheet.setFrozenRows(1);
  }

  if (CONFIG.COLUMN_WIDTH) {
    sheet.setColumnWidths(1, columnCount, CONFIG.COLUMN_WIDTH);
  }

  formatHeader_(sheet, columnCount);
  if (payload.rows.length > 0) {
    formatMemberRows_(sheet, payload.rows, columnCount);
  }

  if (CONFIG.AUTO_RESIZE_COLUMNS) {
    sheet.autoResizeColumns(1, columnCount);
  }
}

function formatHeader_(sheet, columnCount) {
  const range = sheet.getRange(1, 1, 1, columnCount);
  range
    .setBackground(CONFIG.HEADER_BACKGROUND)
    .setFontColor(CONFIG.HEADER_FONT_COLOR)
    .setFontWeight('bold')
    .setHorizontalAlignment('center')
    .setVerticalAlignment('middle');
}

function formatMemberRows_(sheet, rows, columnCount) {
  const rowCount = rows.length;
  const playerRange = sheet.getRange(2, 1, rowCount, 1);
  const pointRange = sheet.getRange(2, 2, rowCount, 1);
  const gearRange = sheet.getRange(2, 3, rowCount, columnCount - 2);

  const playerColors = rows.map((row) => [row.classColor || '#FFFFFF']);
  const pointBackgrounds = rows.map(() => [CONFIG.POINT_BACKGROUND]);
  const gearBackgrounds = rows.map((row, index) => {
    const sheetRow = index + 2;
    const color = sheetRow % 2 === 0 ? CONFIG.ROW_STRIPE_EVEN : CONFIG.ROW_STRIPE_ODD;
    return Array(columnCount - 2).fill(color);
  });

  playerRange
    .setBackground(CONFIG.PLAYER_BACKGROUND)
    .setFontWeight('bold')
    .setHorizontalAlignment('right')
    .setVerticalAlignment('middle')
    .setFontColors(playerColors);

  pointRange
    .setBackgrounds(pointBackgrounds)
    .setFontColor(CONFIG.POINT_FONT_COLOR)
    .setFontWeight('normal')
    .setHorizontalAlignment('center')
    .setVerticalAlignment('middle');

  gearRange
    .setBackgrounds(gearBackgrounds)
    .setHorizontalAlignment('center')
    .setVerticalAlignment('middle');
}

function jsonResponse_(payload) {
  return ContentService
    .createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}
```

## Step 2: Deploy the Apps Script as a Web App

Before you deploy, set the shared secret in Apps Script:

1. Open `Project Settings` in the Apps Script editor.
2. Find `Script properties`.
3. Add a property named `SF_SHARED_SECRET`.
4. Paste in your real shared secret value.
5. Save the property.

1. Click `Deploy` -> `New deployment`.
2. Choose `Web app`.
3. Set `Execute as` to your account.
4. Set access to `Anyone with the link`.
5. Deploy the script.
6. Copy the web app URL.

That URL is the `endpoint_url` value used by the Python utility.

## Step 3: Configure the Python Utility

You can configure the utility with either:

- a JSON config file, which is the easiest option for regular use
- command-line flags

### Recommended: JSON Config File

Download `spectrum_federation_sheet_sync.example.json`, rename it to `spectrum_federation_sheet_sync.json`, and place it next to the Python script.

If you prefer, you can also create the file manually and paste in this JSON:

```json
{
  "endpoint_url": "https://script.google.com/macros/s/REPLACE_WITH_YOUR_DEPLOYMENT_ID/exec",
  "shared_secret": "replace-this-with-a-long-random-secret",
  "saved_variables_path": "",
  "poll_interval_seconds": 10.0,
  "debounce_seconds": 1.5,
  "http_timeout_seconds": 30,
  "retry_attempts": 3
}
```

Configuration notes:

- `endpoint_url`: the deployed Apps Script web app URL.
- `shared_secret`: must exactly match the value stored in the Apps Script Script Property `SF_SHARED_SECRET`.
- `saved_variables_path`: optional. Leave it empty to use auto-discovery.
- `poll_interval_seconds`: how often the script checks the file. The default is 10 seconds.
- `debounce_seconds`: how long the script waits after a change before syncing.
- `http_timeout_seconds`: request timeout for the web call.
- `retry_attempts`: retry count for temporary network failures.

## Step 4: How File Discovery Works

If `saved_variables_path` is blank, the utility tries to locate `SpectrumFederation.lua` automatically.

### macOS

The utility checks common World of Warcraft install locations, including:

```text
/Applications/World of Warcraft/_retail_/WTF/Account/*/SavedVariables/SpectrumFederation.lua
~/Applications/World of Warcraft/_retail_/WTF/Account/*/SavedVariables/SpectrumFederation.lua
~/Games/World of Warcraft/_retail_/WTF/Account/*/SavedVariables/SpectrumFederation.lua
```

### Windows

The utility checks common locations, including:

```text
C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\*\SavedVariables\SpectrumFederation.lua
C:\Program Files\World of Warcraft\_retail_\WTF\Account\*\SavedVariables\SpectrumFederation.lua
C:\Games\World of Warcraft\_retail_\WTF\Account\*\SavedVariables\SpectrumFederation.lua
```

If multiple matching files are found, the script uses the most recently updated one.

### Manual Path Override

If auto-discovery is not correct, set the full file path in either:

- `saved_variables_path` inside the JSON config file
- `--saved-variables-path` on the command line

Example paths:

```text
C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\YourAccount\SavedVariables\SpectrumFederation.lua
/Applications/World of Warcraft/_retail_/WTF/Account/YourAccount/SavedVariables/SpectrumFederation.lua
```

## Step 5: Run the Utility

### From the repo

macOS or Linux:

```bash
python3 assets/spectrum_federation_sheet_sync.py --config assets/spectrum_federation_sheet_sync.json
```

Windows PowerShell:

```powershell
py .\assets\spectrum_federation_sheet_sync.py --config .\assets\spectrum_federation_sheet_sync.json
```

### As a standalone script outside the repo

Copy these files to any folder on your machine:

- `spectrum_federation_sheet_sync.py`

Create `spectrum_federation_sheet_sync.json` in the same folder and paste in the JSON example from this page.

Then run the script from that folder.

macOS or Linux:

```bash
python3 spectrum_federation_sheet_sync.py
```

Windows PowerShell:

```powershell
py .\spectrum_federation_sheet_sync.py
```

The script automatically looks for `spectrum_federation_sheet_sync.json` next to itself.

## Start and Stop Behavior

- The utility runs continuously until you stop it.
- It performs an initial sync when it starts and a new sync whenever the file changes.
- File changes are debounced so one save does not produce multiple uploads.
- To stop it, press `Ctrl+C` or close the terminal window.

## What Gets Written to the Sheet

The sheet is rebuilt on every sync using these headers:

- `Player Name`
- the active profile's point name
- `Helm`
- `Neck`
- `Shoulder`
- `Back`
- `Chest`
- `Wrist`
- `Main Hand`
- `Off Hand`
- `2H-Weapon`
- `Gloves`
- `Belt`
- `Pants`
- `Shoes`
- `Ring`
- `Trinket`

Formatting applied on every update:

- header row: dark gray background, bold white text, centered horizontally, middle aligned vertically
- player name column: dark gray background, bold text, class-colored font, right aligned, middle aligned
- point column: gray background, white text, centered, middle aligned
- gear columns: centered horizontally and vertically
- row striping on member rows across the gear columns

Gear values:

- `✅` means the slot has not been used yet
- `❌` means the slot has been used
- `Ring` shows two emojis for `Ring1` and `Ring2`
- `Trinket` shows two emojis for `Trinket1` and `Trinket2`

## Troubleshooting

### The utility cannot find `SpectrumFederation.lua`

- Set `saved_variables_path` explicitly.
- Verify that the addon has been loaded in-game at least once so the SavedVariables file exists.
- Make sure you are pointing at the `WTF/Account/.../SavedVariables/` copy, not the addon source folder.

### The sheet does not update

- Confirm that the Apps Script deployment URL is correct.
- Confirm that the `shared_secret` matches in both places.
- Watch the terminal output for HTTP or parse errors.
- Make sure the web app deployment allows access with the link.

### The wrong WoW account file is selected

- This usually happens when multiple WoW accounts or installs exist.
- Set `saved_variables_path` manually to the exact account-specific file you want.

## Optional Command-Line Usage

If you prefer not to use a config file, you can pass everything directly:

```bash
python3 assets/spectrum_federation_sheet_sync.py \
  --endpoint-url "https://script.google.com/macros/s/REPLACE_WITH_YOUR_DEPLOYMENT_ID/exec" \
  --shared-secret "replace-this-with-a-long-random-secret" \
  --saved-variables-path "/Applications/World of Warcraft/_retail_/WTF/Account/YourAccount/SavedVariables/SpectrumFederation.lua"
```

Use `--once` if you want to test a single sync and then exit.