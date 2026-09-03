"""
Validate WoW addon package structure for WowUp and CurseForge compatibility.

Checks:
- Parent and child addon directories exist at repo root
- TOC files exist and are correctly named
- TOC files have valid Interface fields and matching Version values
- Test zip has both sibling addon folders at the top level
"""

import argparse
import re
import subprocess
import sys
import zipfile
from pathlib import Path

CHILD_ADDON_NAMES = (
    "SpectrumFederation_CursedSurgeTracker",
    "SpectrumFederation_RCLootCouncilCapture",
)
ZIP_EXCLUDES = ["*.git*", "*/AGENTS.md"]


def toc_field(toc_file, field_name):
    """Return a TOC metadata field value or None."""
    content = Path(toc_file).read_text(encoding="utf-8")
    pattern = re.compile(rf"^## {re.escape(field_name)}:\s*(.+)$", re.MULTILINE)
    match = pattern.search(content)
    if not match:
        return None
    return match.group(1).strip()


def packaged_addon_names(parent_name):
    """Return sibling addon folder names that belong in the release zip."""
    names = [parent_name]
    for child_name in CHILD_ADDON_NAMES:
        if Path(child_name).exists() and child_name != parent_name:
            names.append(child_name)
    return names


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

    toc_base = toc_file.name
    if not (toc_base == f"{addon_name}.toc" or toc_base.startswith(f"{addon_name}_")):
        print(f"::error ::TOC file '{toc_base}' does not start with addon folder name '{addon_name}'")
        print("          This may fail on CurseForge or in-game")
        return False, None

    print(f"[validate-packaging] TOC file name '{toc_base}' is valid for folder '{addon_name}'")
    return True, toc_file


def validate_interface_field(toc_file):
    """Verify TOC has valid Interface field."""
    interface_value = toc_field(toc_file, "Interface")

    if not interface_value:
        print(f"::error ::No '## Interface:' line found in {toc_file}")
        return False

    if not re.match(r"^[0-9,\s]+$", interface_value):
        print(f"::error ::Interface value '{interface_value}' in {toc_file} does not look numeric")
        return False

    print(f"[validate-packaging] Interface value '{interface_value}' looks OK")
    return True


def validate_child_relationship(parent_name, child_name, parent_toc, child_toc):
    """Verify child metadata, dependency direction, and version alignment."""
    parent_interface = toc_field(parent_toc, "Interface")
    child_interface = toc_field(child_toc, "Interface")
    parent_version = toc_field(parent_toc, "Version")
    child_version = toc_field(child_toc, "Version")
    dependencies = toc_field(child_toc, "Dependencies") or ""
    group = toc_field(child_toc, "Group") or ""
    parent_content = Path(parent_toc).read_text(encoding="utf-8")
    child_content = Path(child_toc).read_text(encoding="utf-8")

    ok = True
    if parent_interface != child_interface:
        print(
            f"::error ::Child Interface '{child_interface}' does not match parent '{parent_interface}'"
        )
        ok = False
    if parent_version != child_version:
        print(
            f"::error ::Child Version '{child_version}' does not match parent '{parent_version}'"
        )
        ok = False
    if parent_name not in {part.strip() for part in dependencies.split(",")}:
        print(f"::error ::Child TOC Dependencies must include '{parent_name}'")
        ok = False
    if group != parent_name:
        print(f"::error ::Child TOC Group must be '{parent_name}', found '{group}'")
        ok = False
    if child_name in parent_content or f"{child_name}.lua" in parent_content:
        print("::error ::Parent TOC must not load child-addon files")
        ok = False
    if f"## Dependencies: {child_name}" in parent_content:
        print("::error ::Parent TOC must not depend on the child addon")
        ok = False
    if re.search(r"^## LoadOnDemand:\s*1\s*$", child_content, re.MULTILINE):
        print("::error ::Child addon must not use LoadOnDemand without an explicit loader")
        ok = False
    if ok:
        print("[validate-packaging] Child addon grouping and version metadata look OK")
    return ok


def create_test_zip(addon_names):
    """Create test zip for structure validation."""
    build_dir = Path("build")
    build_dir.mkdir(exist_ok=True)

    zip_name = f"{addon_names[0]}-validation.zip"
    zip_path = build_dir / zip_name

    if zip_path.exists():
        zip_path.unlink()

    print(f"[validate-packaging] Creating test zip: {zip_path}")

    cmd = ["zip", "-r", str(zip_path), *addon_names, "-x", *ZIP_EXCLUDES]
    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print(f"::error ::Failed to create test zip: {e}")
        return False, None

    return True, zip_path


def validate_zip_structure(zip_path, addon_names, toc_files):
    """Verify zip has sibling addon folders at the top level."""
    with zipfile.ZipFile(zip_path, "r") as zf:
        all_files = zf.namelist()

    top_levels = set()
    for file_path in all_files:
        top_level = file_path.split("/")[0]
        top_levels.add(top_level)

    expected = set(addon_names)
    if top_levels != expected:
        print(
            f"::error ::Zip top-level entries are {sorted(top_levels)}, expected {sorted(expected)}"
        )
        print("          WowUp and CurseForge expect addon folder(s) at the root of the zip")
        return False

    for addon_name, toc_file in zip(addon_names, toc_files):
        toc_in_zip = f"{addon_name}/{toc_file.name}"
        if toc_in_zip not in all_files:
            print(f"::error ::TOC file '{toc_in_zip}' not found inside zip")
            return False

    for child_name in CHILD_ADDON_NAMES:
        if child_name in expected:
            nested_child = f"{addon_names[0]}/{child_name}/"
            for file_path in all_files:
                if file_path.startswith(nested_child):
                    print(f"::error ::Child addon files are nested inside the parent folder: {file_path}")
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

    addon_names = packaged_addon_names(args.addon_name)
    toc_files = []

    for addon_name in addon_names:
        if not validate_addon_directory(addon_name):
            sys.exit(1)

        success, toc_file = validate_toc_file(addon_name)
        if not success:
            sys.exit(1)

        if not validate_interface_field(toc_file):
            sys.exit(1)

        toc_files.append(toc_file)

    for index in range(1, len(addon_names)):
        if not validate_child_relationship(
            addon_names[0],
            addon_names[index],
            toc_files[0],
            toc_files[index],
        ):
            sys.exit(1)

    success, zip_path = create_test_zip(addon_names)
    if not success:
        sys.exit(1)

    if not validate_zip_structure(zip_path, addon_names, toc_files):
        sys.exit(1)

    print("[validate-packaging] ✅ Validation successful")
    return 0


if __name__ == "__main__":
    sys.exit(main())
