#!/usr/bin/env python3
"""
Validate WoW addon package structure for WowUp and CurseForge compatibility.

Checks:
- Addon directory exists at repo root
- TOC file exists and is correctly named
- TOC file has valid Interface field
- Test zip has correct structure
"""

import argparse
import re
import subprocess
import sys
import zipfile
from pathlib import Path


def validate_addon_directory(addon_name):
    """Verify addon directory exists."""
    addon_dir = Path(addon_name)
    if not addon_dir.exists():
        print(f"::error ::Addon directory '{addon_name}' not found at repo root")
        return False
    print(f"[validate-packaging] Found addon directory: {addon_name}")
    return True


def validate_toc_file(addon_name):
    """Verify TOC file exists and is correctly named."""
    toc_file = Path(addon_name) / f"{addon_name}.toc"
    
    if not toc_file.exists():
        print(f"::error ::TOC file '{toc_file}' not found")
        return False, None
    
    print(f"[validate-packaging] Using TOC file: {toc_file}")
    
    # Validate TOC name vs folder name
    toc_base = toc_file.name
    if not (toc_base == f"{addon_name}.toc" or toc_base.startswith(f"{addon_name}_")):
        print(f"::error ::TOC file '{toc_base}' does not start with addon folder name '{addon_name}'")
        print("          This may fail on CurseForge or in-game")
        return False, None
    
    print(f"[validate-packaging] TOC file name '{toc_base}' is valid for folder '{addon_name}'")
    return True, toc_file


def validate_interface_field(toc_file):
    """Verify TOC has valid Interface field."""
    content = toc_file.read_text(encoding="utf-8")
    
    # Find Interface line
    interface_pattern = re.compile(r"^## Interface:\s*(.+)$", re.MULTILINE)
    match = interface_pattern.search(content)
    
    if not match:
        print(f"::error ::No '## Interface:' line found in {toc_file}")
        return False
    
    interface_value = match.group(1).strip()
    
    # Validate it looks numeric (may have commas for multiple interfaces)
    if not re.match(r"^[0-9,\s]+$", interface_value):
        print(f"::error ::Interface value '{interface_value}' in {toc_file} does not look numeric")
        return False
    
    print(f"[validate-packaging] Interface value '{interface_value}' looks OK")
    return True


def create_test_zip(addon_name):
    """Create test zip for structure validation."""
    build_dir = Path("build")
    build_dir.mkdir(exist_ok=True)
    
    zip_name = f"{addon_name}-validation.zip"
    zip_path = build_dir / zip_name
    
    # Remove old zip if exists
    if zip_path.exists():
        zip_path.unlink()
    
    print(f"[validate-packaging] Creating test zip: {zip_path}")
    
    # Create zip using subprocess (matches existing script behavior)
    try:
        subprocess.run(
            ["zip", "-r", str(zip_path), addon_name],
            check=True,
            capture_output=True
        )
    except subprocess.CalledProcessError as e:
        print(f"::error ::Failed to create test zip: {e}")
        return False, None
    
    return True, zip_path


def validate_zip_structure(zip_path, addon_name, toc_file):
    """Verify zip has correct structure for WowUp/CurseForge."""
    with zipfile.ZipFile(zip_path, 'r') as zf:
        all_files = zf.namelist()
    
    # Get top-level directories/files
    top_levels = set()
    for file_path in all_files:
        top_level = file_path.split('/')[0]
        top_levels.add(top_level)
    
    # Should only have one top-level: the addon directory
    if top_levels != {addon_name}:
        print(f"::error ::Zip top-level entries are {sorted(top_levels)}, expected only '{addon_name}'")
        print("          WowUp and CurseForge expect the addon folder at the root of the zip")
        return False
    
    # Verify TOC file is in the zip
    toc_in_zip = f"{addon_name}/{toc_file.name}"
    if toc_in_zip not in all_files:
        print(f"::error ::TOC file '{toc_in_zip}' not found inside zip")
        return False
    
    print("[validate-packaging] Zip structure looks good for WowUp and CurseForge")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Validate WoW addon package structure"
    )
    parser.add_argument(
        "--addon-name",
        default="SpectrumFederation",
        help="Name of the addon (default: SpectrumFederation)"
    )
    
    args = parser.parse_args()
    
    print("[validate-packaging] Starting validation...")
    
    # Run all validations
    if not validate_addon_directory(args.addon_name):
        sys.exit(1)
    
    success, toc_file = validate_toc_file(args.addon_name)
    if not success:
        sys.exit(1)
    
    if not validate_interface_field(toc_file):
        sys.exit(1)
    
    success, zip_path = create_test_zip(args.addon_name)
    if not success:
        sys.exit(1)
    
    if not validate_zip_structure(zip_path, args.addon_name, toc_file):
        sys.exit(1)
    
    print("[validate-packaging] ✅ Validation successful")
    return 0


if __name__ == "__main__":
    sys.exit(main())
