#!/usr/bin/env python3
"""
Check if version was bumped in TOC file compared to base branch.

Used in PR validation to ensure version field is updated.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


def extract_version(toc_content):
    """Extract version from TOC file content."""
    pattern = re.compile(r"^## Version:\s*(.+)$", re.MULTILINE | re.IGNORECASE)
    match = pattern.search(toc_content)
    if match:
        return match.group(1).strip()
    return None


def get_current_version(addon_name):
    """Get version from current TOC file."""
    toc_path = Path(addon_name) / f"{addon_name}.toc"
    
    if not toc_path.exists():
        print(f"::error ::TOC file '{toc_path}' not found in PR branch")
        return None
    
    content = toc_path.read_text(encoding="utf-8")
    version = extract_version(content)
    
    if not version:
        print(f"::error ::No '## Version:' line found in {toc_path} on PR branch")
        return None
    
    return version


def get_base_version(addon_name, base_ref):
    """Get version from base branch TOC file."""
    toc_path = f"{addon_name}/{addon_name}.toc"
    
    try:
        result = subprocess.run(
            ["git", "show", f"origin/{base_ref}:{toc_path}"],
            capture_output=True,
            text=True,
            check=True
        )
        base_content = result.stdout
        
    except subprocess.CalledProcessError:
        print(f"[check-version-bump] No TOC file in base branch origin/{base_ref}, probably first release")
        return None
    
    version = extract_version(base_content)
    
    if not version:
        print("[check-version-bump] No '## Version:' in base branch TOC, skipping version bump check")
        return None
    
    return version


def main():
    parser = argparse.ArgumentParser(
        description="Check if addon version was bumped"
    )
    parser.add_argument(
        "base_ref",
        help="Base branch reference (e.g., main, beta)"
    )
    parser.add_argument(
        "--addon-name",
        default="SpectrumFederation",
        help="Name of the addon (default: SpectrumFederation)"
    )
    
    args = parser.parse_args()
    
    print("[check-version-bump] Checking addon version bump...")
    
    # Get current version
    current_version = get_current_version(args.addon_name)
    if current_version is None:
        sys.exit(1)
    
    # Get base version
    base_version = get_base_version(args.addon_name, args.base_ref)
    
    # If no base version, this is probably the first release
    if base_version is None:
        print("[check-version-bump] Skipping version bump check (no base version found)")
        return 0
    
    print(f"[check-version-bump] Base ({args.base_ref}) addon version : {base_version}")
    print(f"[check-version-bump] PR branch addon version        : {current_version}")
    
    # Compare versions
    if current_version == base_version:
        print(f"::error ::Addon '## Version:' in {args.addon_name}/{args.addon_name}.toc is still '{current_version}'")
        print(f"          When merging into '{args.base_ref}', bump the addon version (e.g., 0.0.2 or 0.0.2-beta.1)")
        sys.exit(1)
    
    print("[check-version-bump] ✅ Addon version has been bumped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
