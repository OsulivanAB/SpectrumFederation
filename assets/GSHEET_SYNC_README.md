# Google Sheets Sync for SpectrumFederation

This Python script automatically syncs your SpectrumFederation addon data to a Google Sheet, providing a real-time view of member points and equipment status.

## Features

- 🔄 **Real-time sync**: Watches for changes in your saved variables file and automatically updates the sheet
- 🎨 **Formatted output**: Professional formatting with class colors, headers, and status indicators
- 🔐 **Secure authentication**: Uses OAuth2 for secure Google Sheets access
- ✅ **Equipment tracking**: Visual indicators (✅/❌) for each equipment slot
- 🏷️ **Point tracking**: Displays custom point system values for each member

## Prerequisites

1. **Python 3.7+** installed on your system
2. **Google Account** with access to Google Sheets
3. **Google Cloud Project** with Sheets API enabled (see Setup below)

## Installation

### 1. Install Python Dependencies

```bash
pip install -r gsheet_sync_requirements.txt
```

Or install individually:
```bash
pip install google-auth google-auth-oauthlib google-auth-httplib2
pip install google-api-python-client watchdog
```

### 2. Set Up Google Sheets API

1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Enable the **Google Sheets API**:
   - Navigate to "APIs & Services" > "Library"
   - Search for "Google Sheets API"
   - Click "Enable"
4. Create OAuth 2.0 credentials:
   - Go to "APIs & Services" > "Credentials"
   - Click "Create Credentials" > "OAuth client ID"
   - Select "Desktop app" as the application type
   - Give it a name (e.g., "SpectrumFederation Sync")
   - Click "Create"
5. Download the credentials:
   - Click the download button (⬇️) next to your new OAuth client
   - Save the file as: `~/.spectrum_federation_credentials.json`
     - On Windows: `C:\Users\YourUsername\.spectrum_federation_credentials.json`
     - On Mac/Linux: `~/.spectrum_federation_credentials.json`

For detailed instructions, see: [Google Sheets API Python Quickstart](https://developers.google.com/sheets/api/quickstart/python)

## Usage

### Basic Command

```bash
python3 gsheet_sync.py <path_to_lua_file> <google_sheet_url>
```

### Example

```bash
python3 gsheet_sync.py \
  "/Users/myname/World of Warcraft/_retail_/WTF/Account/ACCOUNT123/SavedVariables/SpectrumFederation.lua" \
  "https://docs.google.com/spreadsheets/d/1abc123def456/edit#gid=0"
```

### Finding Your Files

#### Saved Variables File Location

The SpectrumFederation saved variables file is located at:

**Windows:**
```
C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\YOUR_ACCOUNT\SavedVariables\SpectrumFederation.lua
```

**Mac:**
```
/Applications/World of Warcraft/_retail_/WTF/Account/YOUR_ACCOUNT/SavedVariables/SpectrumFederation.lua
```

Replace `YOUR_ACCOUNT` with your actual WoW account name.

#### Google Sheet URL

1. Create or open a Google Sheet
2. Copy the full URL from your browser (including the `#gid=` part if you want a specific tab)
3. Example: `https://docs.google.com/spreadsheets/d/1abc123def456/edit#gid=0`

## First Run

On the first run, the script will:

1. Open your web browser for Google authentication
2. Ask you to sign in to your Google account
3. Request permission to access Google Sheets
4. Save the authentication token for future runs

After the initial authentication, subsequent runs will use the saved token automatically.

## Output Format

The script creates a formatted Google Sheet with:

### Header Row
- **Columns**: Player Name, [Point Name], Head, Neck, Shoulder, Back, Chest, Bracers, Hands, Belt, Pants, Boots, Ring1, Ring2, Trinket1, Trinket2, Weapon, OffHand
- **Style**: Arial 10pt, bold, white text, dark gray background (#434343)

### Player Names (Column A)
- **Sorted**: Alphabetically by player name
- **Style**: Arial 10pt, bold, class-colored text, dark gray background (#434343)
- **Colors**: Uses official WoW class colors

### Point Values (Column B)
- **Content**: Current point balance for each member
- **Style**: Arial 10pt, white text, gray background (#b7b7b7)

### Equipment Columns (C onwards)
- **Indicators**: ✅ (has item) or ❌ (needs item)
- **Slots**: All armor and weapon slots tracked by the addon

## Running Continuously

The script will:
1. Perform an initial sync
2. Continue watching the saved variables file for changes
3. Automatically update the sheet when changes are detected
4. Run until you press **Ctrl+C** to stop

### Tips for Continuous Running

- Keep the terminal window open while playing WoW
- The script updates automatically when the addon saves data
- Press `Ctrl+C` to stop the sync and close the script

## Troubleshooting

### "Could not find SpectrumFederationDB in file"
- The saved variables file might be corrupted or empty
- Make sure the addon has saved data at least once (log out of WoW)

### "No active profile found"
- You need to create and activate a profile in the addon first
- Go to SpectrumFederation settings and create a Loot Helper profile

### "Missing required dependency"
- Install the required Python packages using pip
- See Installation section above

### Authentication Issues
- Make sure you've placed the credentials file in the correct location
- Check that the Google Sheets API is enabled in your Google Cloud project
- Try deleting `~/.spectrum_federation_token.json` to re-authenticate

### "Permission denied" errors
- Make sure you have write access to the Google Sheet
- If someone else created the sheet, they need to share it with you

## Security Notes

- **Credentials**: Keep your `~/.spectrum_federation_credentials.json` file private
- **Token**: The `~/.spectrum_federation_token.json` file contains your access token
- **Never share**: Do not commit these files to version control or share them publicly
- **Permissions**: The script only requests permission to modify Google Sheets (read/write)

## Advanced Usage

### Custom Sheet Tab

To update a specific tab in a multi-sheet document, include the `gid` in the URL:

```bash
python3 gsheet_sync.py savedvars.lua "https://docs.google.com/spreadsheets/d/YOUR_ID/edit#gid=123456"
```

### Scheduling Updates

On Mac/Linux, you can use `cron` or `systemd` to run the script automatically.

On Windows, use Task Scheduler to start the script when you log in.

## Support

For issues or questions:
- Check the [SpectrumFederation repository](https://github.com/OsulivanAB/SpectrumFederation)
- Open an issue on GitHub
- Consult the addon documentation

## License

This script is part of the SpectrumFederation project and follows the same license.
