# SpectrumFederation Google Sheets Sync (Simple Version)

A simple, no-configuration-required solution for syncing your SpectrumFederation addon data to Google Sheets using Google Apps Script.

**No OAuth! No Google Cloud Project! No Dependencies!**

## Features

- ✅ **Simple Configuration**: Edit variables at the top of the file - no command-line arguments
- ✅ **Zero Setup**: No API keys, no credentials files, no OAuth setup
- ✅ **Standard Library Only**: No external Python dependencies to install
- ✅ **Real-time Sync**: Watches your saved variables file and auto-updates
- ✅ **Professional Formatting**: Class colors, equipment status, point tracking
- ✅ **Drop-in Ready**: Just configure and run

## Quick Start

### Step 1: Deploy the Google Apps Script

1. **Open your Google Sheet** (or create a new one)
2. Click **Extensions** → **Apps Script**
3. **Delete** any default code in the editor
4. **Copy and paste** the entire contents of `SpectrumFederationSync.gs` (in this folder)
5. **Edit line 23** to set your sheet tab name:
   ```javascript
   const SHEET_NAME = "Sheet1";  // Change to your sheet name
   ```
6. Click **Deploy** → **New deployment**
7. Click the gear icon ⚙️ and select **Web app**
8. Configure:
   - **Description**: SpectrumFederation Sync
   - **Execute as**: Me
   - **Who has access**: Anyone
9. Click **Deploy**
10. **Copy the Web App URL** - you'll need this for the Python script

**Important**: If you update the Apps Script later, you need to create a **New deployment** (not update the existing one) for changes to take effect.

### Step 2: Configure and Run the Python Script

**No installation required!** Uses only Python's standard library.

1. **Edit the configuration** in `gsheet_sync.py`:
   - Open the file in a text editor
   - Find the configuration section near the top (around line 35)
   - Set `LUA_FILE_PATH` to your saved variables file location
   - Set `API_URL` to your Google Apps Script Web App URL
   - Optionally set `TEST_MODE = True` for a test run

2. **Run the script**:
   ```bash
   python3 gsheet_sync.py
   ```

**Configuration Example:**

```python
# Path to your SpectrumFederation.lua saved variables file
LUA_FILE_PATH = r"C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\ACCOUNT123\SavedVariables\SpectrumFederation.lua"

# Your Google Apps Script Web App URL (from deployment)
API_URL = "https://script.google.com/macros/s/YOUR_SCRIPT_ID/exec"

# Test mode: Set to True to run once and exit (no file watching)
TEST_MODE = False
```

**Platform-specific paths:**
- **Windows**: `r"C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\ACCOUNT123\SavedVariables\SpectrumFederation.lua"`
- **Mac**: `"/Applications/World of Warcraft/_retail_/WTF/Account/ACCOUNT123/SavedVariables/SpectrumFederation.lua"`
- **Linux**: `"/home/user/WoW/_retail_/WTF/Account/ACCOUNT123/SavedVariables/SpectrumFederation.lua"`

### Step 3: Verify It Works

The script will:
1. Parse your saved variables file
2. Send the data to your Apps Script
3. Update your Google Sheet with formatted data
4. Continue watching for file changes

Press **Ctrl+C** to stop the sync.

## Testing

### Test the Apps Script (Optional)

In the Apps Script editor:
1. Select the `testUpdate` function from the dropdown
2. Click **Run**
3. Grant permissions when prompted
4. Check your sheet - you should see test data

### Test the Python Script

Set `TEST_MODE = True` in the configuration to do one sync and exit:

```python
TEST_MODE = True  # Run once and exit
```

Then run:
```bash
python3 gsheet_sync.py
```

After testing, set it back to `False` for continuous monitoring.

## Output Format

The script creates a formatted Google Sheet with:

### Header Row
- **Columns**: Player Name, [Point Name], Head, Neck, Shoulder, Back, Chest, Bracers, Hands, Belt, Pants, Boots, Ring1, Ring2, Trinket1, Trinket2, Weapon, OffHand
- **Style**: Arial 10pt, bold, white text, dark gray background (#434343)

### Player Names (Column A)
- **Sorted**: Alphabetically by player name
- **Style**: Arial 10pt, bold, class-colored text (official WoW colors), dark gray background (#434343)

### Point Values (Column B)
- **Content**: Current point balance for each member
- **Style**: Arial 10pt, white text, gray background (#b7b7b7)

### Equipment Columns (C+)
- **Indicators**: ✅ (has item) or ❌ (needs item)
- **16 Slots**: All armor and weapon slots tracked by the addon

## Troubleshooting

### "Error parsing Lua file"
- Make sure the file path is correct
- Ensure the addon has saved data at least once (log out of WoW)

### "No active profile found"
- You need to create and activate a Loot Helper profile in the addon
- Go to SpectrumFederation settings → Loot Helper → Create a profile

### "HTTP 403" or "HTTP 405" Error
- Your Apps Script deployment might not be set to "Anyone" access
- Redeploy with "Who has access: Anyone"
- Make sure you're using the Web App URL (ends with `/exec`), not the script editor URL

### "Connection error" or Timeout
- Check your internet connection
- Verify the API URL is correct
- Try the `--test` flag to test the connection once

### Changes Not Appearing
- Apps Script changes require a **new deployment**, not updating an existing one
- After editing the script, go to Deploy → New deployment
- Use the new URL in your Python script

### Permission Prompts
When you first run the Apps Script:
1. Google will show a warning "This app isn't verified"
2. Click "Advanced"
3. Click "Go to SpectrumFederation Sync (unsafe)"
4. Click "Allow"

This is normal for personal Apps Script projects.

## How It Works

1. **Python Script**:
   - Parses your WoW addon saved variables file (Lua format)
   - Extracts the active profile's member and equipment data
   - Sends it as JSON to the Apps Script API via HTTP POST

2. **Google Apps Script**:
   - Receives the JSON data
   - Clears and updates the specified sheet
   - Applies all formatting (colors, fonts, sizes)
   - Returns success/error status

3. **File Watching**:
   - Python script monitors the file every 2 seconds
   - When WoW saves new data, the script automatically syncs
   - No manual intervention needed

## Advanced Usage

### Change Sheet Name

Edit line 23 in `SpectrumFederationSync.gs`:
```javascript
const SHEET_NAME = "MyCustomSheetName";
```

Then create a **new deployment** for the change to take effect.

### Multiple Profiles

To sync multiple profiles to different sheets:
1. Deploy the Apps Script multiple times (once per sheet)
2. Each deployment gets its own URL
3. Create multiple copies of `gsheet_sync.py` with different configurations
4. Run each instance separately

### Scheduling

**Windows**: Use Task Scheduler to start the script on login

**Mac/Linux**: Create a startup script or use `systemd`

## Security Notes

- ✅ No credentials stored locally
- ✅ Apps Script runs with your Google account permissions
- ✅ "Anyone" access means anyone with the URL can POST data
- ✅ The URL acts as the security key - keep it private
- ✅ You can revoke access by disabling the deployment in Apps Script

## Comparison to OAuth Version

| Feature | Apps Script (This) | OAuth Version |
|---------|-------------------|---------------|
| Setup complexity | ⭐ Simple | ⭐⭐⭐⭐⭐ Complex |
| Google Cloud Project | ❌ Not needed | ✅ Required |
| External dependencies | ❌ None | ✅ 5 packages |
| Credential files | ❌ None | ✅ 2 files |
| API quotas | Generous | Same |
| Security | URL-based | OAuth2 tokens |

## Support

For issues or questions:
- Check the [SpectrumFederation repository](https://github.com/OsulivanAB/SpectrumFederation)
- Open an issue on GitHub
- Review the Troubleshooting section above

## License

This script is part of the SpectrumFederation project and follows the same license.
