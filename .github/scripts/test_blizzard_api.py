#!/usr/bin/env python3
"""
Test Blizzard API endpoints for game version queries.

This script helps verify which authentication method (if any) is required
for querying WoW game version from Blizzard's patch servers.

Usage:
    python3 test_blizzard_api.py --environment live
    python3 test_blizzard_api.py --environment beta

Manual Testing Instructions:
    1. Run this script for both live and beta environments
    2. Check which auth method works (or if no auth is needed)
    3. Verify the response format contains version information
    4. Update blizzard_api.py with the working method
    
Expected Response Format (unknown - to be determined):
    - May be JSON with version field
    - May be plain text
    - May require parsing
"""

import argparse
import sys
import urllib.request
import urllib.error
import os

# Endpoints provided by Gemini (to be verified)
ENDPOINTS = {
    "live": "http://us.patch.battle.net:1119/wow/versions",
    "beta": "http://us.patch.battle.net:1119/wow_beta/versions"
}

PRODUCT_CODES = {
    "live": "wow",
    "beta": "wow_beta"
}


def test_no_auth(url):
    """Test endpoint with no authentication."""
    print("\n[TEST 1] No Authentication")
    print(f"GET {url}")
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = response.read().decode('utf-8')
            print(f"✓ Status: {response.status}")
            print(f"✓ Response:\n{data[:500]}")  # First 500 chars
            return True, data
    except urllib.error.HTTPError as e:
        print(f"✗ HTTP Error: {e.code} {e.reason}")
        return False, None
    except Exception as e:
        print(f"✗ Error: {e}")
        return False, None


def test_bearer_token(url, token):
    """Test endpoint with Bearer token authentication."""
    print("\n[TEST 2] Bearer Token Authentication")
    print(f"GET {url}")
    print("Authorization: Bearer <token>")
    
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {token}")
    
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            data = response.read().decode('utf-8')
            print(f"✓ Status: {response.status}")
            print(f"✓ Response:\n{data[:500]}")
            return True, data
    except urllib.error.HTTPError as e:
        print(f"✗ HTTP Error: {e.code} {e.reason}")
        return False, None
    except Exception as e:
        print(f"✗ Error: {e}")
        return False, None


def test_api_key_header(url, api_id, api_secret):
    """Test endpoint with API key in header."""
    print("\n[TEST 3] API Key Header Authentication")
    print(f"GET {url}")
    print(f"X-API-ID: {api_id}")
    print("X-API-Secret: <secret>")
    
    req = urllib.request.Request(url)
    req.add_header("X-API-ID", api_id)
    req.add_header("X-API-Secret", api_secret)
    
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            data = response.read().decode('utf-8')
            print(f"✓ Status: {response.status}")
            print(f"✓ Response:\n{data[:500]}")
            return True, data
    except urllib.error.HTTPError as e:
        print(f"✗ HTTP Error: {e.code} {e.reason}")
        return False, None
    except Exception as e:
        print(f"✗ Error: {e}")
        return False, None


def test_api_key_query_param(url, api_id, api_secret):
    """Test endpoint with API key as query parameter."""
    print("\n[TEST 4] API Key Query Parameter Authentication")
    test_url = f"{url}?api_id={api_id}&api_secret={api_secret}"
    print(f"GET {url}?api_id={api_id}&api_secret=<secret>")
    
    try:
        with urllib.request.urlopen(test_url, timeout=10) as response:
            data = response.read().decode('utf-8')
            print(f"✓ Status: {response.status}")
            print(f"✓ Response:\n{data[:500]}")
            return True, data
    except urllib.error.HTTPError as e:
        print(f"✗ HTTP Error: {e.code} {e.reason}")
        return False, None
    except Exception as e:
        print(f"✗ Error: {e}")
        return False, None


def main():
    parser = argparse.ArgumentParser(
        description="Test Blizzard API endpoints for WoW game version queries"
    )
    parser.add_argument(
        "--environment",
        choices=["live", "beta"],
        required=True,
        help="Which environment to test (live or beta)"
    )
    parser.add_argument(
        "--api-id",
        default=os.getenv("BLIZZARD_API_ID", "test-api-id"),
        help="Blizzard API ID (default: $BLIZZARD_API_ID or 'test-api-id')"
    )
    parser.add_argument(
        "--api-secret",
        default=os.getenv("BLIZZARD_API_SECRET", "test-api-secret"),
        help="Blizzard API Secret (default: $BLIZZARD_API_SECRET or 'test-api-secret')"
    )
    
    args = parser.parse_args()
    
    url = ENDPOINTS[args.environment]
    product_code = PRODUCT_CODES[args.environment]
    
    print("=" * 70)
    print(f"Testing Blizzard API - {args.environment.upper()} Environment")
    print("=" * 70)
    print(f"Endpoint: {url}")
    print(f"Product Code: {product_code}")
    
    # Test different authentication methods
    results = []
    
    # Test 1: No auth
    success, data = test_no_auth(url)
    results.append(("No Auth", success, data))
    
    # Test 2: Bearer token (combine api_id:api_secret as token)
    token = f"{args.api_id}:{args.api_secret}"
    success, data = test_bearer_token(url, token)
    results.append(("Bearer Token", success, data))
    
    # Test 3: API key header
    success, data = test_api_key_header(url, args.api_id, args.api_secret)
    results.append(("API Key Header", success, data))
    
    # Test 4: API key query param
    success, data = test_api_key_query_param(url, args.api_id, args.api_secret)
    results.append(("API Key Query Param", success, data))
    
    # Summary
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    
    working_methods = [method for method, success, _ in results if success]
    
    if working_methods:
        print(f"✓ Working authentication methods: {', '.join(working_methods)}")
        print("\nNext steps:")
        print("1. Update blizzard_api.py to use the working authentication method")
        print("2. Parse the response format to extract version information")
        print("3. Add error handling for network failures")
    else:
        print("✗ No authentication methods worked")
        print("\nPossible reasons:")
        print("- Endpoint URL is incorrect")
        print("- Different authentication method required")
        print("- Endpoint requires VPN or IP whitelist")
        print("- Endpoint is deprecated or moved")
        print("\nRecommended actions:")
        print("1. Verify endpoint URLs with Blizzard documentation")
        print("2. Check if Battle.net OAuth is required")
        print("3. Consider manual Interface version management as fallback")
    
    return 0 if working_methods else 1


if __name__ == "__main__":
    sys.exit(main())
