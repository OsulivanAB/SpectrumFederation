#!/usr/bin/env python3
"""
Blizzard API client for querying WoW game versions.

Retrieves current Interface version from Blizzard's patch server.
No authentication required - endpoints are publicly accessible.
"""

import argparse
import re
import sys
import urllib.request
import urllib.error


ENDPOINTS = {
    "live": "http://us.patch.battle.net:1119/wow/versions",
    "beta": "http://us.patch.battle.net:1119/wow_beta/versions"
}


def parse_version_response(response_text):
    """
    Parse Blizzard's version response.
    
    Format:
        Region!STRING:0|BuildConfig!HEX:16|...
        us|hash|hash|hash|64978|11.2.7.64978|hash
    
    Returns:
        Version string (e.g., "11.2.7.64978") or None
    """
    lines = response_text.strip().split('\n')
    
    # Find the 'us' region line
    for line in lines:
        if line.startswith('us|'):
            parts = line.split('|')
            # Version is typically in format: Major.Minor.Patch.Build
            # Usually in the 6th column (index 5)
            if len(parts) >= 6:
                version_candidate = parts[5]
                # Validate it looks like a version
                if re.match(r'^\d+\.\d+\.\d+\.\d+$', version_candidate):
                    return version_candidate
    
    return None


def version_to_interface(version):
    """
    Convert game version to Interface version.
    
    Example:
        11.2.7.64978 -> 110207
        12.0.1.64914 -> 120001
    
    Format: Major Minor Patch (6 digits, zero-padded)
    """
    parts = version.split('.')
    if len(parts) < 3:
        return None
    
    try:
        major = int(parts[0])
        minor = int(parts[1])
        patch = int(parts[2])
        
        # Format as 6-digit interface version
        interface = f"{major}{minor:02d}{patch:02d}"
        return interface
        
    except (ValueError, IndexError):
        return None


def get_game_version(environment="live"):
    """
    Query Blizzard API for current game version.
    
    Args:
        environment: "live" or "beta"
    
    Returns:
        tuple: (version_string, interface_version) or (None, None) on error
    """
    if environment not in ENDPOINTS:
        print(f"Error: Invalid environment '{environment}'. Use 'live' or 'beta'", file=sys.stderr)
        return None, None
    
    url = ENDPOINTS[environment]
    
    print(f"[blizzard-api] Querying {environment} endpoint: {url}", file=sys.stderr)
    
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = response.read().decode('utf-8')
            
        version = parse_version_response(data)
        
        if not version:
            print("Error: Could not parse version from Blizzard API response", file=sys.stderr)
            return None, None
        
        interface = version_to_interface(version)
        
        if not interface:
            print(f"Error: Could not convert version '{version}' to Interface format", file=sys.stderr)
            return None, None
        
        print(f"[blizzard-api] Game version: {version}", file=sys.stderr)
        print(f"[blizzard-api] Interface version: {interface}", file=sys.stderr)
        
        return version, interface
        
    except urllib.error.HTTPError as e:
        print(f"Error: HTTP {e.code} {e.reason} when querying Blizzard API", file=sys.stderr)
        return None, None
    except urllib.error.URLError as e:
        print(f"Error: Failed to reach Blizzard API: {e.reason}", file=sys.stderr)
        return None, None
    except Exception as e:
        print(f"Error: Unexpected error querying Blizzard API: {e}", file=sys.stderr)
        return None, None


def main():
    parser = argparse.ArgumentParser(
        description="Query Blizzard API for WoW game version"
    )
    parser.add_argument(
        "--environment",
        choices=["live", "beta"],
        default="live",
        help="Which environment to query (default: live)"
    )
    parser.add_argument(
        "--output",
        choices=["version", "interface", "both"],
        default="both",
        help="What to output (default: both)"
    )
    
    args = parser.parse_args()
    
    version, interface = get_game_version(args.environment)
    
    if version is None or interface is None:
        sys.exit(1)
    
    # Output based on requested format
    if args.output == "version":
        print(version)
    elif args.output == "interface":
        print(interface)
    else:  # both
        print(f"Version: {version}")
        print(f"Interface: {interface}")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
