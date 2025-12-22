#!/usr/bin/env python3
"""
Package addon and create GitHub release.

Creates a zip file with proper structure and publishes to GitHub Releases.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path


def create_addon_zip(addon_name, version):
    """Create addon zip file with proper structure."""
    build_dir = Path("build")
    build_dir.mkdir(exist_ok=True)
    
    zip_name = f"{addon_name}-{version}.zip"
    zip_path = build_dir / zip_name
    
    # Remove old zip if exists
    if zip_path.exists():
        zip_path.unlink()
    
    print(f"[publish-release] Creating release zip: {zip_path}")
    
    # Create zip using subprocess for consistency with validation
    try:
        subprocess.run(
            ["zip", "-r", str(zip_path), addon_name, "-x", "*.git*"],
            check=True,
            capture_output=True
        )
        print(f"[publish-release] ✓ Created {zip_path}")
        return zip_path
        
    except subprocess.CalledProcessError as e:
        print(f"::error ::Failed to create release zip: {e}")
        return None


def create_github_release(version, zip_path, repo, is_prerelease=False, dry_run=False):
    """Create GitHub release and upload asset using gh CLI."""
    github_token = os.environ.get("GITHUB_TOKEN")
    if not github_token:
        print("Error: GITHUB_TOKEN environment variable not set")
        return False
    
    tag_name = f"v{version}"
    release_name = f"Release {version}"
    
    # Determine release notes
    if "-beta" in version:
        notes = f"Beta release {version}\n\nSee [CHANGELOG.md](https://github.com/{repo}/blob/beta/CHANGELOG.md) for details."
    else:
        notes = f"Stable release {version}\n\nSee [CHANGELOG.md](https://github.com/{repo}/blob/main/CHANGELOG.md) for details."
    
    if dry_run:
        print("[publish-release] DRY RUN - Would create release:")
        print(f"  Tag: {tag_name}")
        print(f"  Name: {release_name}")
        print(f"  Prerelease: {is_prerelease}")
        print(f"  Asset: {zip_path}")
        print(f"  Notes: {notes}")
        return True
    
    print(f"[publish-release] Creating GitHub release: {tag_name}")
    
    # Build gh CLI command
    cmd = [
        "gh", "release", "create",
        tag_name,
        str(zip_path),
        "--title", release_name,
        "--notes", notes,
    ]
    
    if is_prerelease:
        cmd.append("--prerelease")
    
    try:
        result = subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            text=True,
            env={**os.environ, "GH_TOKEN": github_token}
        )
        
        print("[publish-release] ✓ Release created successfully")
        if result.stdout:
            print(result.stdout)
        
        return True
        
    except subprocess.CalledProcessError as e:
        print(f"::error ::Failed to create GitHub release: {e}")
        if e.stderr:
            print(e.stderr, file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Package addon and create GitHub release"
    )
    parser.add_argument(
        "version",
        help="Version to release (e.g., 0.0.15 or 0.0.15-beta.1)"
    )
    parser.add_argument(
        "--addon-name",
        default="SpectrumFederation",
        help="Name of the addon (default: SpectrumFederation)"
    )
    parser.add_argument(
        "--repo",
        default="OsulivanAB/SpectrumFederation",
        help="GitHub repository (default: OsulivanAB/SpectrumFederation)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Don't actually create release, just show what would be done"
    )
    
    args = parser.parse_args()
    
    # Determine if this is a prerelease
    is_prerelease = "-beta" in args.version or "-alpha" in args.version or "-rc" in args.version
    
    print("[publish-release] Starting release process...")
    print(f"[publish-release] Version: {args.version}")
    print(f"[publish-release] Prerelease: {is_prerelease}")
    
    # Create zip
    zip_path = create_addon_zip(args.addon_name, args.version)
    if not zip_path:
        sys.exit(1)
    
    # Create GitHub release
    success = create_github_release(
        args.version,
        zip_path,
        args.repo,
        is_prerelease=is_prerelease,
        dry_run=args.dry_run
    )
    
    if not success:
        sys.exit(1)
    
    print("[publish-release] ✅ Release published successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
