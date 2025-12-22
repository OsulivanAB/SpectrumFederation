#!/usr/bin/env python3
"""
Check if a GitHub release already exists for the given version.

Used to prevent duplicate beta releases with the same version.
"""

import argparse
import os
import sys


def check_duplicate_release(version, repo):
    """Check if a release with this version already exists."""
    # Import here to avoid dependency issues if requests not available
    try:
        import requests
    except ImportError:
        print("Error: requests library not available")
        print("Install with: pip install requests")
        sys.exit(1)
    
    github_token = os.environ.get("GITHUB_TOKEN")
    if not github_token:
        print("Warning: GITHUB_TOKEN not set, skipping duplicate check")
        return False
    
    print(f"[check-duplicate-release] Checking for existing release: {version}")
    
    # GitHub API endpoint for releases
    api_url = f"https://api.github.com/repos/{repo}/releases"
    
    headers = {
        "Authorization": f"Bearer {github_token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
    }
    
    try:
        response = requests.get(api_url, headers=headers, timeout=30)
        response.raise_for_status()
        releases = response.json()
        
    except requests.RequestException as e:
        print(f"Warning: Failed to fetch releases: {e}")
        return False
    
    # Check if version exists in releases
    for release in releases:
        release_tag = release.get("tag_name", "")
        release_name = release.get("name", "")
        
        # Check both tag and name
        if version in release_tag or version in release_name:
            print(f"::error ::A release with version '{version}' already exists")
            print(f"          Tag: {release_tag}")
            print(f"          Name: {release_name}")
            print(f"          URL: {release.get('html_url', 'N/A')}")
            print("          Bump the version in the TOC file to create a new release")
            return True
    
    print(f"[check-duplicate-release] ✓ No existing release found for version {version}")
    return False


def main():
    parser = argparse.ArgumentParser(
        description="Check for duplicate GitHub releases"
    )
    parser.add_argument(
        "version",
        help="Version to check (e.g., 0.0.15-beta.1)"
    )
    parser.add_argument(
        "--repo",
        default="OsulivanAB/SpectrumFederation",
        help="GitHub repository (default: OsulivanAB/SpectrumFederation)"
    )
    
    args = parser.parse_args()
    
    if check_duplicate_release(args.version, args.repo):
        sys.exit(1)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
