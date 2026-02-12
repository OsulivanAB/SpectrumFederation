#!/usr/bin/env python3
"""
Google Sheets Sync for SpectrumFederation

This script parses the SpectrumFederation saved variables file and updates
a Google Sheet with member information, point balances, and equipment status.

Features:
- Parses Lua saved variables file
- Authenticates with Google Sheets API
- Updates sheet with formatted member data
- Watches for file changes and auto-updates
- Supports Ctrl+C to exit gracefully

Requirements:
- google-auth
- google-auth-oauthlib
- google-auth-httplib2
- google-api-python-client
- watchdog
"""

import argparse
import json
import os
import re
import signal
import sys
import time
from pathlib import Path
from urllib.parse import urlparse, parse_qs

try:
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
except ImportError as e:
    print(f"Error: Missing required dependency: {e}")
    print("\nPlease install required packages:")
    print("  pip install google-auth google-auth-oauthlib google-auth-httplib2")
    print("  pip install google-api-python-client watchdog")
    sys.exit(1)


# Google Sheets API scope
SCOPES = ['https://www.googleapis.com/auth/spreadsheets']

# WoW class colors (hex format without #)
CLASS_COLORS = {
    'DEATHKNIGHT': 'C41E3A',
    'DEMONHUNTER': 'A330C9',
    'DRUID': 'FF7C0A',
    'EVOKER': '33937F',
    'HUNTER': 'AAD372',
    'MAGE': '3FC7EB',
    'MONK': '00FF98',
    'PALADIN': 'F48CBA',
    'PRIEST': 'FFFFFF',
    'ROGUE': 'FFF468',
    'SHAMAN': '0070DD',
    'WARLOCK': '8788EE',
    'WARRIOR': 'C69B6D',
}

# Equipment slot order (as they should appear in columns)
EQUIPMENT_SLOTS = [
    'Head', 'Neck', 'Shoulder', 'Back', 'Chest',
    'Bracers', 'Hands', 'Belt', 'Pants', 'Boots',
    'Ring1', 'Ring2', 'Trinket1', 'Trinket2',
    'Weapon', 'OffHand'
]


def parse_lua_table(content, start_pos=0):
    """
    Parse a Lua table from string content.
    This is a simplified parser that handles the SpectrumFederation format.
    """
    result = {}
    array_result = []
    i = start_pos
    is_array = True
    array_index = 1
    
    while i < len(content):
        # Skip whitespace
        while i < len(content) and content[i] in ' \t\n\r':
            i += 1
        
        if i >= len(content):
            break
            
        # Check for end of table
        if content[i] == '}':
            if is_array and len(array_result) > 0:
                return array_result, i + 1
            return result, i + 1
        
        # Parse key
        if content[i] == '[':
            # Bracketed key
            i += 1
            if content[i] == '"':
                # String key
                i += 1
                key_start = i
                while i < len(content) and content[i] != '"':
                    if content[i] == '\\':
                        i += 2
                    else:
                        i += 1
                key = content[key_start:i]
                i += 1  # Skip closing quote
                # Skip to ]
                while i < len(content) and content[i] != ']':
                    i += 1
                i += 1  # Skip ]
                is_array = False
            else:
                # Numeric key
                key_start = i
                while i < len(content) and content[i] not in ']':
                    i += 1
                key = content[key_start:i].strip()
                i += 1  # Skip ]
                try:
                    key_num = int(key)
                    if key_num != array_index:
                        is_array = False
                    else:
                        array_index += 1
                except ValueError:
                    is_array = False
        else:
            # For array elements without explicit index
            key = None
        
        # Skip whitespace and =
        while i < len(content) and content[i] in ' \t\n\r=':
            i += 1
        
        # Parse value
        if i >= len(content):
            break
            
        value = None
        if content[i] == '{':
            # Nested table
            i += 1
            value, i = parse_lua_table(content, i)
        elif content[i] == '"':
            # String value
            i += 1
            value_start = i
            while i < len(content) and content[i] != '"':
                if content[i] == '\\':
                    i += 2
                else:
                    i += 1
            value = content[value_start:i]
            i += 1  # Skip closing quote
        elif content[i:i+4] == 'true':
            value = True
            i += 4
        elif content[i:i+5] == 'false':
            value = False
            i += 5
        else:
            # Numeric value
            value_start = i
            while i < len(content) and content[i] not in ',}\n\r':
                i += 1
            value_str = content[value_start:i].strip()
            if value_str:
                try:
                    if '.' in value_str:
                        value = float(value_str)
                    else:
                        value = int(value_str)
                except ValueError:
                    value = value_str
        
        # Store the key-value pair
        if key is None:
            # Array element
            array_result.append(value)
        else:
            is_array = False
            result[key] = value
        
        # Skip to next element
        while i < len(content) and content[i] in ' \t\n\r,':
            i += 1
    
    if is_array and len(array_result) > 0:
        return array_result, i
    return result, i


def parse_lua_file(file_path):
    """Parse the SpectrumFederation saved variables file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find the SpectrumFederationDB table
        match = re.search(r'SpectrumFederationDB\s*=\s*{', content)
        if not match:
            raise ValueError("Could not find SpectrumFederationDB in file")
        
        start_pos = match.end()
        data, _ = parse_lua_table(content, start_pos)
        
        return data
    except Exception as e:
        raise Exception(f"Error parsing Lua file: {e}")


def get_active_profile(data):
    """Extract the active profile from the parsed data."""
    if 'lootHelper' not in data:
        raise ValueError("No lootHelper data found")
    
    loot_helper = data['lootHelper']
    
    if 'profiles' not in loot_helper:
        raise ValueError("No profiles found in lootHelper")
    
    profiles = loot_helper['profiles']
    
    # Find the active profile
    for profile_id, profile in profiles.items():
        if isinstance(profile, dict) and profile.get('_activeProfile'):
            return profile
    
    raise ValueError("No active profile found")


def extract_sheet_info(gsheet_url):
    """
    Extract spreadsheet ID and sheet name from a Google Sheets URL.
    
    Supports URLs like:
    - https://docs.google.com/spreadsheets/d/{id}/edit#gid={gid}
    - https://docs.google.com/spreadsheets/d/{id}/edit?gid={gid}
    """
    parsed = urlparse(gsheet_url)
    
    # Extract spreadsheet ID from path
    path_parts = parsed.path.split('/')
    if 'spreadsheets' in path_parts and 'd' in path_parts:
        d_index = path_parts.index('d')
        if d_index + 1 < len(path_parts):
            spreadsheet_id = path_parts[d_index + 1]
        else:
            raise ValueError("Could not extract spreadsheet ID from URL")
    else:
        raise ValueError("Invalid Google Sheets URL format")
    
    # Extract sheet GID from fragment or query
    sheet_gid = None
    if parsed.fragment:
        gid_match = re.search(r'gid=(\d+)', parsed.fragment)
        if gid_match:
            sheet_gid = gid_match.group(1)
    
    if not sheet_gid and parsed.query:
        query_params = parse_qs(parsed.query)
        if 'gid' in query_params:
            sheet_gid = query_params['gid'][0]
    
    return spreadsheet_id, sheet_gid


def get_sheet_name_from_gid(service, spreadsheet_id, gid):
    """Get the sheet name from a GID."""
    if not gid:
        # Return first sheet
        sheet_metadata = service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
        sheets = sheet_metadata.get('sheets', [])
        if sheets:
            return sheets[0]['properties']['title']
        return 'Sheet1'
    
    try:
        sheet_metadata = service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
        sheets = sheet_metadata.get('sheets', [])
        for sheet in sheets:
            if str(sheet['properties']['sheetId']) == str(gid):
                return sheet['properties']['title']
    except HttpError as e:
        print(f"Warning: Could not retrieve sheet name (using 'Sheet1'): {e.status_code} {e.error_details}")
    except Exception as e:
        print(f"Warning: Could not retrieve sheet name (using 'Sheet1'): {e}")
    
    return 'Sheet1'


def authenticate_google_sheets():
    """Authenticate with Google Sheets API."""
    creds = None
    token_path = Path.home() / '.spectrum_federation_token.json'
    credentials_path = Path.home() / '.spectrum_federation_credentials.json'
    
    # Check for existing token
    if token_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)
        # Ensure token file has restrictive permissions (owner read/write only)
        try:
            os.chmod(token_path, 0o600)
        except (OSError, AttributeError):
            pass  # Windows or permission issues
    
    # If no valid credentials, authenticate
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not credentials_path.exists():
                print("\nGoogle Sheets API Setup Required")
                print("=" * 50)
                print("\nTo use this script, you need to set up Google Sheets API access:")
                print("\n1. Go to: https://console.cloud.google.com/")
                print("2. Create a new project or select existing")
                print("3. Enable the Google Sheets API")
                print("4. Create OAuth 2.0 credentials (Desktop app)")
                print("5. Download the credentials JSON file")
                print(f"6. Save it as: {credentials_path}")
                print("\nFor detailed instructions, visit:")
                print("https://developers.google.com/sheets/api/quickstart/python")
                print("\n" + "=" * 50 + "\n")
                sys.exit(1)
            
            flow = InstalledAppFlow.from_client_secrets_file(
                str(credentials_path), SCOPES)
            creds = flow.run_local_server(port=0)
        
        # Save credentials with restrictive permissions
        with open(token_path, 'w') as token:
            token.write(creds.to_json())
        try:
            os.chmod(token_path, 0o600)
        except (OSError, AttributeError):
            pass  # Windows or permission issues
    
    return creds


def hex_to_rgb(hex_color):
    """Convert hex color to RGB dict for Google Sheets API."""
    hex_color = hex_color.lstrip('#')
    return {
        'red': int(hex_color[0:2], 16) / 255.0,
        'green': int(hex_color[2:4], 16) / 255.0,
        'blue': int(hex_color[4:6], 16) / 255.0
    }


def update_google_sheet(service, spreadsheet_id, sheet_name, profile):
    """Update the Google Sheet with profile data."""
    
    # Extract data from profile
    members = profile.get('_members', [])
    point_name = profile.get('_pointName', 'Points')
    
    # Sort members alphabetically by name
    sorted_members = sorted(members, key=lambda m: m.get('name', '').lower())
    
    # Prepare header row
    headers = ['Player Name', point_name] + EQUIPMENT_SLOTS
    
    # Prepare data rows
    data_rows = [headers]
    for member in sorted_members:
        row = [
            member.get('name', ''),
            member.get('pointBalance', 0)
        ]
        
        # Add equipment status
        armor = member.get('armor', {})
        for slot in EQUIPMENT_SLOTS:
            has_item = armor.get(slot, False)
            row.append('✅' if has_item else '❌')
        
        data_rows.append(row)
    
    # Clear existing data
    range_name = f"{sheet_name}!A1:Z1000"
    try:
        service.spreadsheets().values().clear(
            spreadsheetId=spreadsheet_id,
            range=range_name
        ).execute()
    except HttpError as e:
        # 404 or similar - sheet might be empty or range doesn't exist yet
        if e.status_code not in (404, 400):
            print(f"Warning: Error clearing sheet: {e.status_code}")
        pass
    
    # Write data
    body = {'values': data_rows}
    service.spreadsheets().values().update(
        spreadsheetId=spreadsheet_id,
        range=f"{sheet_name}!A1",
        valueInputOption='RAW',
        body=body
    ).execute()
    
    # Get sheet ID for formatting
    sheet_metadata = service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
    sheets = sheet_metadata.get('sheets', [])
    sheet_id = None
    for sheet in sheets:
        if sheet['properties']['title'] == sheet_name:
            sheet_id = sheet['properties']['sheetId']
            break
    
    if sheet_id is None:
        print("Warning: Could not find sheet ID for formatting")
        return
    
    # Prepare formatting requests
    requests = []
    
    # Header row formatting (Row 1)
    # Background: #434343, Text: white, Arial 10, bold
    requests.append({
        'repeatCell': {
            'range': {
                'sheetId': sheet_id,
                'startRowIndex': 0,
                'endRowIndex': 1,
            },
            'cell': {
                'userEnteredFormat': {
                    'backgroundColor': hex_to_rgb('#434343'),
                    'textFormat': {
                        'foregroundColor': hex_to_rgb('#FFFFFF'),
                        'fontFamily': 'Arial',
                        'fontSize': 10,
                        'bold': True
                    }
                }
            },
            'fields': 'userEnteredFormat(backgroundColor,textFormat)'
        }
    })
    
    # Column A formatting (Player names)
    # Background: #434343, Text: class color, Arial 10, bold
    for i, member in enumerate(sorted_members):
        row_index = i + 1  # +1 because row 0 is headers
        class_name = member.get('class', 'WARRIOR').upper()
        class_color = CLASS_COLORS.get(class_name, 'FFFFFF')
        
        requests.append({
            'repeatCell': {
                'range': {
                    'sheetId': sheet_id,
                    'startRowIndex': row_index,
                    'endRowIndex': row_index + 1,
                    'startColumnIndex': 0,
                    'endColumnIndex': 1
                },
                'cell': {
                    'userEnteredFormat': {
                        'backgroundColor': hex_to_rgb('#434343'),
                        'textFormat': {
                            'foregroundColor': hex_to_rgb(class_color),
                            'fontFamily': 'Arial',
                            'fontSize': 10,
                            'bold': True
                        }
                    }
                },
                'fields': 'userEnteredFormat(backgroundColor,textFormat)'
            }
        })
    
    # Column B formatting (Points)
    # Background: #b7b7b7, Text: white, Arial 10, not bold
    if len(sorted_members) > 0:
        requests.append({
            'repeatCell': {
                'range': {
                    'sheetId': sheet_id,
                    'startRowIndex': 1,
                    'endRowIndex': len(sorted_members) + 1,
                    'startColumnIndex': 1,
                    'endColumnIndex': 2
                },
                'cell': {
                    'userEnteredFormat': {
                        'backgroundColor': hex_to_rgb('#b7b7b7'),
                        'textFormat': {
                            'foregroundColor': hex_to_rgb('#FFFFFF'),
                            'fontFamily': 'Arial',
                            'fontSize': 10,
                            'bold': False
                        }
                    }
                },
                'fields': 'userEnteredFormat(backgroundColor,textFormat)'
            }
        })
    
    # Apply all formatting
    if requests:
        service.spreadsheets().batchUpdate(
            spreadsheetId=spreadsheet_id,
            body={'requests': requests}
        ).execute()
    
    print(f"✓ Updated sheet with {len(sorted_members)} members")


class LuaFileChangeHandler(FileSystemEventHandler):
    """Handle file system events for the Lua file."""
    
    def __init__(self, file_path, callback):
        self.file_path = Path(file_path).resolve()
        self.callback = callback
        self.last_modified = 0
        
    def on_modified(self, event):
        if event.is_directory:
            return
        
        event_path = Path(event.src_path).resolve()
        if event_path == self.file_path:
            # Debounce: only trigger if at least 1 second has passed
            current_time = time.time()
            if current_time - self.last_modified > 1:
                self.last_modified = current_time
                print(f"\n[{time.strftime('%H:%M:%S')}] File changed, updating sheet...")
                self.callback()


def main():
    parser = argparse.ArgumentParser(
        description='Sync SpectrumFederation data to Google Sheets'
    )
    parser.add_argument(
        'file_path',
        help='Path to the SpectrumFederation.lua saved variables file'
    )
    parser.add_argument(
        'gsheet_url',
        help='Google Sheet URL (including sheet tab)'
    )
    
    args = parser.parse_args()
    
    # Validate file exists
    lua_file = Path(args.file_path)
    if not lua_file.exists():
        print(f"Error: File not found: {args.file_path}")
        sys.exit(1)
    
    print("SpectrumFederation → Google Sheets Sync")
    print("=" * 50)
    
    # Authenticate
    print("\n[1/4] Authenticating with Google Sheets...")
    creds = authenticate_google_sheets()
    service = build('sheets', 'v4', credentials=creds)
    print("✓ Authenticated")
    
    # Parse sheet URL
    print("\n[2/4] Parsing Google Sheet URL...")
    try:
        spreadsheet_id, sheet_gid = extract_sheet_info(args.gsheet_url)
        sheet_name = get_sheet_name_from_gid(service, spreadsheet_id, sheet_gid)
        print(f"✓ Spreadsheet ID: {spreadsheet_id}")
        print(f"✓ Sheet name: {sheet_name}")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
    
    # Define update function
    def update_sheet():
        try:
            # Parse Lua file
            data = parse_lua_file(args.file_path)
            
            # Get active profile
            profile = get_active_profile(data)
            profile_name = profile.get('_profileName', 'Unknown')
            print(f"✓ Active profile: {profile_name}")
            
            # Update sheet
            update_google_sheet(service, spreadsheet_id, sheet_name, profile)
            
        except Exception as e:
            print(f"✗ Error: {e}")
    
    # Initial update
    print("\n[3/4] Processing initial update...")
    update_sheet()
    
    # Set up file watching
    print("\n[4/4] Watching for file changes...")
    print("Press Ctrl+C to stop\n")
    
    event_handler = LuaFileChangeHandler(args.file_path, update_sheet)
    observer = Observer()
    observer.schedule(event_handler, str(lua_file.parent), recursive=False)
    observer.start()
    
    # Set up signal handler for graceful exit
    def signal_handler(sig, frame):
        print("\n\nShutting down...")
        observer.stop()
        observer.join()
        print("✓ Stopped watching for changes")
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    
    # Keep running (signal handler will catch Ctrl+C)
    while True:
        time.sleep(1)


if __name__ == '__main__':
    main()
