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
SAFE_TOC_FIELDS = frozenset(
    {
        "version",
        "x-wago-id",
        "x-website",
        "x-documentation",
        "x-license",
        "x-category",
        "x-curse-project-id",
        "x-wowinterface-id",
        "x-wowi-id",
    }
)
RUNTIME_TOC_FIELDS = frozenset(
    {
        "interface",
        "dependencies",
        "optionaldeps",
        "requireddeps",
        "loadondemand",
        "loadwith",
        "loadmanagers",
        "savedvariables",
        "savedvariablespercharacter",
        "secure",
        "defaultstate",
    }
)
CHECKBOX_RE = re.compile(r"-\s*\[([\sxX])\]\s*(.+)")
TOC_METADATA_RE = re.compile(r"^##\s*([^:]+?)(?:\s*:\s*(.*))?$")
DIFF_GIT_RE = re.compile(r"^diff --git a/(.+) b/(.+)$")


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


def _normalize_repo_path(path):
    """Normalize a repository-relative path for addon-tree checks."""
    return str(path or "").replace("\\", "/").lstrip("./")


def is_addon_runtime_path(path):
    """Return True for packaged addon Lua/XML that players load in-game."""
    normalized = _normalize_repo_path(path)
    if not any(normalized.startswith(root) for root in ADDON_RUNTIME_ROOTS):
        return False
    return normalized.lower().endswith(ADDON_RUNTIME_SUFFIXES)


def is_addon_toc_path(path):
    """Return True for a packaged addon TOC file."""
    normalized = _normalize_repo_path(path)
    if not any(normalized.startswith(root) for root in ADDON_RUNTIME_ROOTS):
        return False
    return normalized.lower().endswith(".toc")


def addon_runtime_changes(paths):
    """Return runtime addon paths from a changed-file list."""
    return [path for path in paths if is_addon_runtime_path(path)]


def addon_toc_changes(paths):
    """Return packaged addon TOC paths from a changed-file list."""
    return [path for path in paths if is_addon_toc_path(path)]


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


def get_changed_toc_lines(diff_text):
    """Parse a unified diff into {path: ['+line', '-line', ...]} or None if malformed."""
    if diff_text is None:
        return None
    if not isinstance(diff_text, str):
        return None

    lines = diff_text.splitlines()
    if not lines:
        return {}

    looks_unified = any(
        line.startswith(("diff --git ", "+++ ", "@@"))
        for line in lines
    )
    if not looks_unified:
        return None

    files = {}
    current = None
    for line in lines:
        if line.startswith("diff --git "):
            match = DIFF_GIT_RE.match(line)
            if not match:
                return None
            current = _normalize_repo_path(match.group(2))
            files.setdefault(current, [])
            continue
        if line.startswith("+++ "):
            target = line[4:].strip()
            if target != "/dev/null":
                current = _normalize_repo_path(target.removeprefix("b/"))
                files.setdefault(current, [])
            continue
        if line.startswith(
            ("--- ", "@@", "index ", "new file", "deleted file", "old mode", "new mode", "\\")
        ):
            continue
        if line.startswith(("+", "-")):
            if current is None:
                return None
            files.setdefault(current, []).append(line)
    return files


def classify_toc_line(line):
    """Return ('safe'|'runtime'|'unknown', name) for one TOC line without +/- prefix."""
    stripped = (line or "").strip()
    if not stripped:
        return "safe", "blank"
    if stripped.startswith("#@"):
        return "unknown", "packaging-directive"
    if stripped.startswith("##"):
        match = TOC_METADATA_RE.match(stripped)
        if not match:
            return "unknown", "malformed-metadata"
        field = (match.group(1) or "").strip().lower()
        if not field:
            return "unknown", "malformed-metadata"
        if field in SAFE_TOC_FIELDS:
            return "safe", field
        if field in RUNTIME_TOC_FIELDS:
            return "runtime", field
        return "unknown", field
    if stripped.startswith("#"):
        return "safe", "comment"
    return "runtime", "file-list"


def classify_toc_change(changed_lines):
    """Return reasons a single TOC hunk is not safe for in-game testing N/A."""
    if changed_lines is None:
        return ["TOC diff hunks are unavailable"]
    if not changed_lines:
        return ["TOC diff hunks are empty or ambiguous"]

    reasons = []
    for raw in changed_lines:
        if not raw or raw[0] not in "+-":
            reasons.append("TOC diff contains an unprefixed or malformed hunk line")
            continue
        kind, name = classify_toc_line(raw[1:])
        if kind == "safe":
            continue
        if kind == "runtime" and name == "file-list":
            path = raw[1:].strip() or "<empty>"
            reasons.append(f"TOC file-list/load-order change requires in-game testing: {path}")
            continue
        if kind == "runtime":
            reasons.append(f"TOC field '## {name}' requires in-game testing")
            continue
        reasons.append(
            f"Unknown or unallowlisted TOC change '{name}' requires in-game testing"
        )
    return reasons


def toc_changes_require_in_game_testing(toc_paths, toc_diffs):
    """Return reasons N/A is unsafe for the given TOC paths and parsed diffs."""
    if not toc_paths:
        return []
    if toc_diffs is None:
        return [
            "TOC diff is unavailable or malformed, so in-game testing N/A is not allowed"
        ]

    reasons = []
    for path in toc_paths:
        normalized = _normalize_repo_path(path)
        if normalized not in toc_diffs:
            reasons.append(f"Changed TOC file '{path}' has no inspectable diff hunks")
            continue
        file_reasons = classify_toc_change(toc_diffs[normalized])
        reasons.extend(f"{path}: {reason}" for reason in file_reasons)
    return reasons


def load_toc_diffs(toc_paths):
    """Load unified TOC diffs from env or git. None means unavailable/malformed."""
    if not toc_paths:
        return {}

    if "PR_TOC_DIFF_PATH" in os.environ:
        path = os.environ.get("PR_TOC_DIFF_PATH")
        if not path:
            return None
        return get_changed_toc_lines(Path(path).read_text(encoding="utf-8"))

    if "PR_TOC_DIFF" in os.environ:
        return get_changed_toc_lines(os.environ.get("PR_TOC_DIFF", ""))

    base = os.environ.get("PR_BASE_SHA")
    head = os.environ.get("PR_HEAD_SHA")
    if not base or not head:
        return None

    result = subprocess.run(
        ["git", "diff", f"{base}...{head}", "--", *toc_paths],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    parsed = get_changed_toc_lines(result.stdout)
    if parsed is None:
        return None
    if result.stdout.strip() and not parsed:
        return None
    return parsed


def validate_in_game_testing(checklist_section, changed_files, toc_diffs="auto"):
    """Require exactly one in-game testing state; N/A cannot cover runtime changes."""
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

    toc_paths = addon_toc_changes(changed_files)
    if not toc_paths:
        return errors

    resolved_diffs = load_toc_diffs(toc_paths) if toc_diffs == "auto" else toc_diffs
    toc_reasons = toc_changes_require_in_game_testing(toc_paths, resolved_diffs)
    errors.extend(
        "In-game testing is not applicable cannot be selected: " + reason
        for reason in toc_reasons
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
