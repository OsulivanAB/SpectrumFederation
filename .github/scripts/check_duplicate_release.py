#!/usr/bin/env python3
"""
Check if a GitHub release already exists for the given version.

Used to prevent duplicate beta releases with the same version.
"""

import argparse
import os
import re
import sys


def parse_version(version_string):
    """
    Parse version string into base version and beta suffix.
    
    Examples:
        "0.0.16-beta.1" -> ("0.0.16", "beta.1")
        "0.0.16" -> ("0.0.16", None)
    """
    match = re.match(r"^(\d+\.\d+\.\d+)(?:-(.+))?$", version_string)
    if not match:
        return None, None
    
    base_version = match.group(1)
    suffix = match.group(2)
    return base_version, suffix


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
    
    # Parse the version
    base_version, suffix = parse_version(version)
    if base_version is None:
        print(f"Warning: Could not parse version '{version}', expected format: X.Y.Z or X.Y.Z-beta.N")
        return False
    
    print(f"[check-duplicate-release] Base version: {base_version}, Suffix: {suffix or 'none (stable)'}")
    
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
    
    # Check for conflicts
    for release in releases:
        release_tag = release.get("tag_name", "").lstrip("v")
        
        # Parse release version
        release_base, release_suffix = parse_version(release_tag)
        if release_base is None:
            continue
        
        # Check 1: Exact version match
        if version == release_tag:
            print(f"::error ::A release with version '{version}' already exists")
            print(f"          Tag: {release.get('tag_name', 'N/A')}")
            print(f"          Name: {release.get('name', 'N/A')}")
            print(f"          URL: {release.get('html_url', 'N/A')}")
            print("          Bump the version in the TOC file to create a new release")
            return True
        
        # Check 2: If we're creating a beta, check if stable version already exists
        if suffix and suffix.startswith("beta") and base_version == release_base and release_suffix is None:
            print(f"::error ::Cannot create beta version '{version}' - stable release '{release_tag}' already exists")
            print(f"          Tag: {release.get('tag_name', 'N/A')}")
            print(f"          Name: {release.get('name', 'N/A')}")
            print(f"          URL: {release.get('html_url', 'N/A')}")
            print("          You cannot create a beta for a version that has already been released as stable")
            print(f"          Bump to the next version (e.g., {increment_version(base_version)}-beta.1)")
            return True
    
    print(f"[check-duplicate-release] ✓ No existing release found for version {version}")
    return False


def increment_version(version_string):
    """Increment the patch version (X.Y.Z -> X.Y.Z+1)."""
    parts = version_string.split(".")
    if len(parts) == 3:
        try:
            parts[2] = str(int(parts[2]) + 1)
            return ".".join(parts)
        except ValueError:
            pass
    return version_string


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
