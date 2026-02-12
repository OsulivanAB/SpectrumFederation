# Quick Start Guide for gsheet_sync.py

## Installation

1. **Install Python dependencies:**
   ```bash
   cd assets
   pip install -r gsheet_sync_requirements.txt
   ```

2. **Set up Google Sheets API credentials:**
   - Follow the instructions in `GSHEET_SYNC_README.md`
   - Place credentials file at: `~/.spectrum_federation_credentials.json`

## Usage

### Basic Usage

```bash
python3 gsheet_sync.py <path_to_lua_file> <google_sheet_url>
```

### Example - Windows

```bash
python3 gsheet_sync.py ^
  "C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\ACCOUNT123\SavedVariables\SpectrumFederation.lua" ^
  "https://docs.google.com/spreadsheets/d/1abc123def456/edit#gid=0"
```

### Example - Mac/Linux

```bash
python3 gsheet_sync.py \
  "/Applications/World of Warcraft/_retail_/WTF/Account/ACCOUNT123/SavedVariables/SpectrumFederation.lua" \
  "https://docs.google.com/spreadsheets/d/1abc123def456/edit#gid=0"
```

### Example - Relative Path

```bash
# If you have a copy of the saved variables file locally
python3 gsheet_sync.py ./SpectrumFederation.lua "https://docs.google.com/spreadsheets/d/YOUR_ID/edit#gid=0"
```

## What It Does

1. **Initial Sync**: 
   - Parses your saved variables file
   - Identifies the active profile
   - Clears and updates the Google Sheet with formatted data

2. **Continuous Monitoring**:
   - Watches the file for changes
   - Automatically re-syncs when the file is updated
   - Runs until you press Ctrl+C

3. **Output Format**:
   - Headers with equipment slot names
   - Alphabetically sorted member list
   - Class-colored player names
   - Point balances
   - Equipment status (✅ = has, ❌ = needs)

## First Run

On your first run, the script will:
1. Open your web browser
2. Ask you to sign in to Google
3. Request permission to access Google Sheets
4. Save authentication for future runs

## Stopping the Script

Press **Ctrl+C** in the terminal to stop the sync gracefully.

## Troubleshooting

### Script won't start
- Check that all dependencies are installed
- Verify Python 3.7+ is installed: `python3 --version`

### Can't find credentials file
- Make sure you saved it as `~/.spectrum_federation_credentials.json`
- On Windows: `C:\Users\YourName\.spectrum_federation_credentials.json`
- On Mac/Linux: `/home/yourname/.spectrum_federation_credentials.json`

### No active profile found
- Open WoW and the SpectrumFederation addon
- Create a Loot Helper profile
- Make sure it's set as active
- Log out of WoW to save the data

### Permission denied on Google Sheet
- Make sure you own the sheet or have edit access
- Try creating a new sheet and using that URL

## Tips

- **Keep it running**: Leave the script running while you play WoW for real-time updates
- **Share the sheet**: Give view access to guild members so they can see the status
- **Multiple tabs**: You can run multiple instances for different profiles/sheets
- **Test first**: Use a test sheet first to make sure everything works

## Support

For more detailed information, see `GSHEET_SYNC_README.md` in this directory.
