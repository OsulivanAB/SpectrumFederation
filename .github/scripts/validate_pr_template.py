"""
Validates that PR descriptions follow the required template format.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

IN_GAME_TESTED_PHRASE = "i have tested these changes in-game"
IN_GAME_NA_PHRASE = "in-game testing is not applicable"
OPTIONAL_CHECKLIST_PHRASES = (
    "linked this pr to any related issues",
)
IN_GAME_CHECKLIST_PHRASES = (
    IN_GAME_TESTED_PHRASE,
    IN_GAME_NA_PHRASE,
)
ADDON_RUNTIME_ROOTS = (
    "SpectrumFederation/",
    "SpectrumFederation_CursedSurgeTracker/",
)
ADDON_RUNTIME_SUFFIXES = (".lua", ".xml")
CHECKBOX_RE = re.compile(r"-\s*\[([\sxX])\]\s*(.+)")


def parse_pr_body(body):
    """Parse PR body and extract sections."""
    if not body:
        return None, None

    # Find Type of Change section
    type_of_change_pattern = r'## Type of Change\s*(.*?)(?=##|\Z)'
    type_match = re.search(type_of_change_pattern, body, re.DOTALL | re.IGNORECASE)
    type_section = type_match.group(1).strip() if type_match else None

    # Find Checklist section
    checklist_pattern = r'## Checklist\s*(.*?)(?=##|\Z)'
    checklist_match = re.search(checklist_pattern, body, re.DOTALL | re.IGNORECASE)
    checklist_section = checklist_match.group(1).strip() if checklist_match else None

    return type_section, checklist_section


def iter_checkboxes(section):
    """Yield (checked, label) pairs for markdown checkboxes in a section."""
    if not section:
        return
    for match in CHECKBOX_RE.finditer(section):
        yield match.group(1).lower() == "x", match.group(2).strip()


def checkbox_checked(section, phrase):
    """Return True/False when a checkbox label contains phrase, else None."""
    needle = phrase.lower()
    found = None
    for checked, label in iter_checkboxes(section):
        if needle in label.lower():
            found = checked
    return found


def count_checkboxes(section, optional_phrases=None):
    """Count total and checked checkboxes in a section."""
    if not section:
        return 0, 0

    optional_phrases = optional_phrases or []
    total = 0
    checked = 0

    for is_checked, label in iter_checkboxes(section):
        lowered = label.lower()
        if any(phrase in lowered for phrase in optional_phrases):
            continue

        total += 1
        if is_checked:
            checked += 1

    return total, checked


def is_addon_runtime_path(path):
    """Return True for packaged addon Lua/XML that players load in-game."""
    normalized = str(path or "").replace("\\", "/").lstrip("./")
    if not any(normalized.startswith(root) for root in ADDON_RUNTIME_ROOTS):
        return False
    return normalized.lower().endswith(ADDON_RUNTIME_SUFFIXES)


def addon_runtime_changes(paths):
    """Return runtime addon paths from a changed-file list."""
    return [path for path in paths if is_addon_runtime_path(path)]


def load_changed_files():
    """Load PR changed files from env, a file, or git. None means unknown."""
    path = os.environ.get("PR_CHANGED_FILES_PATH")
    if path:
        return [
            line.strip()
            for line in Path(path).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    if "PR_CHANGED_FILES" in os.environ:
        return [
            line.strip()
            for line in os.environ.get("PR_CHANGED_FILES", "").splitlines()
            if line.strip()
        ]

    base = os.environ.get("PR_BASE_SHA")
    head = os.environ.get("PR_HEAD_SHA")
    if not base or not head:
        return None

    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...{head}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def validate_in_game_testing(checklist_section, changed_files):
    """Require exactly one in-game testing state; N/A cannot cover runtime Lua/XML."""
    errors = []
    tested = checkbox_checked(checklist_section, IN_GAME_TESTED_PHRASE)
    not_applicable = checkbox_checked(checklist_section, IN_GAME_NA_PHRASE)
    tested_on = bool(tested)
    na_on = bool(not_applicable)

    if tested_on and na_on:
        errors.append(
            "Select exactly one in-game testing state: tested in-game, or not applicable, not both"
        )
        return errors

    if not tested_on and not na_on:
        errors.append(
            "Select exactly one in-game testing state: tested in-game, or not applicable"
        )
        return errors

    if not na_on:
        return errors

    if changed_files is None:
        errors.append(
            "In-game testing N/A requires a changed-file list "
            "(PR_CHANGED_FILES, PR_CHANGED_FILES_PATH, or PR_BASE_SHA/PR_HEAD_SHA) "
            "so addon Lua/XML changes cannot skip Retail QA"
        )
        return errors

    runtime_paths = addon_runtime_changes(changed_files)
    if runtime_paths:
        shown = ", ".join(runtime_paths[:5])
        extra = "" if len(runtime_paths) <= 5 else f" (+{len(runtime_paths) - 5} more)"
        errors.append(
            "In-game testing is not applicable cannot be selected when addon "
            f"Lua/XML runtime files changed: {shown}{extra}"
        )
    return errors


def main():
    pr_body = os.environ.get('PR_BODY', '')

    if not pr_body:
        print("❌ ERROR: PR body is empty")
        sys.exit(1)

    print("🔍 Validating PR description...")
    print()

    # Parse sections
    type_section, checklist_section = parse_pr_body(pr_body)

    errors = []

    # Validate Type of Change section
    if not type_section:
        errors.append("Missing '## Type of Change' section")
    else:
        total_type, checked_type = count_checkboxes(type_section)
        print(f"✓ Found 'Type of Change' section with {total_type} options")

        if checked_type == 0:
            errors.append("No checkbox is selected in 'Type of Change' section")
        else:
            print(f"✓ {checked_type} type(s) selected")

    print()

    # Validate Checklist section
    if not checklist_section:
        errors.append("Missing '## Checklist' section")
    else:
        # Linked-issue remains optional. In-game tested vs N/A is validated
        # separately so exactly one testing state can be selected.
        skipped_checklist_phrases = OPTIONAL_CHECKLIST_PHRASES + IN_GAME_CHECKLIST_PHRASES
        total_checklist, checked_checklist = count_checkboxes(
            checklist_section,
            skipped_checklist_phrases,
        )
        print(f"✓ Found 'Checklist' section with {total_checklist} required items")

        if total_checklist == 0:
            errors.append("No checklist items found in 'Checklist' section")
        elif checked_checklist < total_checklist:
            errors.append(
                f"Not all checklist items are checked: {checked_checklist}/{total_checklist} completed"
            )
        else:
            print(f"✓ All {total_checklist} required checklist items are checked")

        changed_files = load_changed_files()
        in_game_errors = validate_in_game_testing(checklist_section, changed_files)
        if not in_game_errors:
            tested = checkbox_checked(checklist_section, IN_GAME_TESTED_PHRASE)
            if tested:
                print("✓ In-game testing is marked complete")
            else:
                print("✓ In-game testing is marked not applicable")
        errors.extend(in_game_errors)

    print()

    # Report results
    if errors:
        print("❌ PR description validation FAILED:")
        print()
        for error in errors:
            print(f"  • {error}")
        print()
        sys.exit(1)
    else:
        print("✅ PR description validation PASSED!")
        sys.exit(0)


if __name__ == '__main__':
    main()
