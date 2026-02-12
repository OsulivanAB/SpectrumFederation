#!/usr/bin/env python3
"""
SpectrumFederation Google Sheets Sync (Simple Version)

This script parses the SpectrumFederation saved variables file and sends
the data to a Google Apps Script Web App that updates your Google Sheet.

No OAuth, no Google Cloud project needed! Just deploy the Apps Script
and use its URL.

Requirements:
- Python 3.7+
- No external dependencies (uses only standard library)

Usage:
    python3 gsheet_sync.py <lua_file_path> <apps_script_url>

Example:
    python3 gsheet_sync.py SpectrumFederation.lua https://script.google.com/macros/s/ABC123/exec
"""

import argparse
import json
import re
import signal
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

# Equipment slot order
EQUIPMENT_SLOTS = [
    'Head', 'Neck', 'Shoulder', 'Back', 'Chest',
    'Bracers', 'Hands', 'Belt', 'Pants', 'Boots',
    'Ring1', 'Ring2', 'Trinket1', 'Trinket2',
    'Weapon', 'OffHand'
]


def parse_lua_table(content, start_pos=0):
    """
    Parse a Lua table from string content.
    Simple parser for the SpectrumFederation format.
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
                i += 1
                while i < len(content) and content[i] != ']':
                    i += 1
                i += 1
                is_array = False
            else:
                # Numeric key
                key_start = i
                while i < len(content) and content[i] not in ']':
                    i += 1
                key = content[key_start:i].strip()
                i += 1
                try:
                    key_num = int(key)
                    if key_num != array_index:
                        # Non-sequential index - convert to dict
                        is_array = False
                        for idx, val in enumerate(array_result, 1):
                            result[str(idx)] = val
                        array_result = []
                    else:
                        # Sequential index
                        array_index += 1
                        key = None
                except ValueError:
                    is_array = False
                    for idx, val in enumerate(array_result, 1):
                        result[str(idx)] = val
                    array_result = []
        else:
            key = None
        
        # Skip whitespace and =
        while i < len(content) and content[i] in ' \t\n\r=':
            i += 1
        
        if i >= len(content):
            break
            
        # Parse value
        value = None
        if content[i] == '{':
            i += 1
            value, i = parse_lua_table(content, i)
        elif content[i] == '"':
            i += 1
            value_start = i
            while i < len(content) and content[i] != '"':
                if content[i] == '\\':
                    i += 2
                else:
                    i += 1
            value = content[value_start:i]
            i += 1
        elif content[i:i+4] == 'true':
            value = True
            i += 4
        elif content[i:i+5] == 'false':
            value = False
            i += 5
        else:
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
    
    for profile_id, profile in profiles.items():
        if isinstance(profile, dict) and profile.get('_activeProfile'):
            return profile
    
    raise ValueError("No active profile found")


def prepare_data_for_api(profile):
    """Convert profile data to the format expected by the Apps Script API."""
    members = profile.get('_members', [])
    point_name = profile.get('_pointName', 'Points')
    
    # Sort members alphabetically by name
    sorted_members = sorted(members, key=lambda m: m.get('name', '').lower())
    
    # Prepare member data
    api_members = []
    for member in sorted_members:
        armor = member.get('armor', {})
        
        api_member = {
            'name': member.get('name', ''),
            'class': member.get('class', 'WARRIOR'),
            'points': member.get('pointBalance', 0),
            'equipment': {slot: armor.get(slot, False) for slot in EQUIPMENT_SLOTS}
        }
        api_members.append(api_member)
    
    return {
        'pointName': point_name,
        'equipmentSlots': EQUIPMENT_SLOTS,
        'members': api_members
    }


def send_to_api(api_url, data):
    """Send data to the Google Apps Script API."""
    try:
        json_data = json.dumps(data).encode('utf-8')
        
        request = Request(
            api_url,
            data=json_data,
            headers={
                'Content-Type': 'application/json',
                'Content-Length': len(json_data)
            },
            method='POST'
        )
        
        with urlopen(request, timeout=30) as response:
            response_data = response.read().decode('utf-8')
            result = json.loads(response_data)
            
            if not result.get('success'):
                raise Exception(f"API error: {result.get('error', 'Unknown error')}")
            
            return result
            
    except HTTPError as e:
        error_body = e.read().decode('utf-8', errors='ignore')
        raise Exception(f"HTTP {e.code}: {error_body}")
    except URLError as e:
        raise Exception(f"Connection error: {e.reason}")
    except Exception as e:
        raise Exception(f"Request failed: {e}")


class FileWatcher:
    """Simple file watcher using modification time."""
    
    def __init__(self, file_path, callback):
        # Accept either string path or resolved Path object
        self.file_path = file_path if isinstance(file_path, Path) else Path(file_path).resolve()
        self.callback = callback
        self.last_mtime = 0
        self.running = False
        
    def start(self):
        """Start watching the file."""
        self.running = True
        print(f"Watching {self.file_path} for changes...")
        print("Press Ctrl+C to stop\n")
        
        while self.running:
            try:
                current_mtime = self.file_path.stat().st_mtime
                
                if self.last_mtime > 0 and current_mtime > self.last_mtime:
                    print(f"\n[{time.strftime('%H:%M:%S')}] File changed, updating sheet...")
                    self.callback()
                
                self.last_mtime = current_mtime
                time.sleep(2)  # Check every 2 seconds
                
            except FileNotFoundError:
                print(f"Warning: File {self.file_path} not found")
                time.sleep(5)
            except Exception as e:
                print(f"Error while watching: {e}")
                time.sleep(5)
    
    def stop(self):
        """Stop watching the file."""
        self.running = False


def main():
    parser = argparse.ArgumentParser(
        description='Sync SpectrumFederation data to Google Sheets (via Apps Script)'
    )
    parser.add_argument(
        'file_path',
        help='Path to the SpectrumFederation.lua saved variables file'
    )
    parser.add_argument(
        'api_url',
        help='Google Apps Script Web App URL (from deployment)'
    )
    parser.add_argument(
        '--test',
        action='store_true',
        help='Test API connection and exit (no file watching)'
    )
    
    args = parser.parse_args()
    
    # Validate file exists
    lua_file = Path(args.file_path).resolve()  # Resolve to absolute path
    if not lua_file.exists():
        print(f"Error: File not found: {lua_file}")
        sys.exit(1)
    
    print("SpectrumFederation → Google Sheets Sync (Simple)")
    print("=" * 60)
    print(f"File: {lua_file}")
    print(f"API: {args.api_url}")
    print("=" * 60)
    
    def update_sheet():
        """Parse file and send to API."""
        try:
            # Parse Lua file
            data = parse_lua_file(args.file_path)
            
            # Get active profile
            profile = get_active_profile(data)
            profile_name = profile.get('_profileName', 'Unknown')
            
            # Prepare data for API
            api_data = prepare_data_for_api(profile)
            
            print(f"Profile: {profile_name}")
            print(f"Members: {len(api_data['members'])}")
            
            # Send to API
            result = send_to_api(args.api_url, api_data)
            print(f"✓ {result.get('message', 'Success')}")
            
        except Exception as e:
            print(f"✗ Error: {e}")
    
    # Initial update
    print("\n[Initial Update]")
    update_sheet()
    
    # Test mode - exit after first update
    if args.test:
        print("\nTest mode - exiting")
        return
    
    # Set up file watching
    print("\n[Watching for changes]")
    watcher = FileWatcher(lua_file, update_sheet)  # Pass already-resolved path
    
    def signal_handler(sig, frame):
        print("\n\nShutting down...")
        watcher.stop()
        print("✓ Stopped watching for changes")
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    
    try:
        watcher.start()
    except KeyboardInterrupt:
        signal_handler(None, None)


if __name__ == '__main__':
    main()
