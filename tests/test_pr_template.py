"""Tests for PR template validation, including human-owned checklist items."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / ".github" / "scripts"
VALIDATOR = SCRIPTS_DIR / "validate_pr_template.py"

REQUIRED = [
    "- [x] My code follows the project's style guidelines",
    "- [x] I have added/updated documentation as needed",
    "- [x] I have added appropriate Debug Logging if necessary",
    "- [x] I have added/updated localization strings in `locale/enUS.lua` if applicable",
    "- [x] My changes generate no new warnings or errors",
    "- [x] Any dependent changes have been merged and published",
]


def _body(*checklist_items: str) -> str:
    return (
        "## Type of Change\n\n- [x] New feature\n\n## Checklist\n\n"
        + "\n".join(checklist_items)
        + "\n"
    )


def _run_validator(body: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PR_BODY"] = body
    return subprocess.run(
        [sys.executable, str(VALIDATOR)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_in_game_testing_unchecked_does_not_fail_validation():
    result = _run_validator(
        _body(
            "- [ ] I have tested these changes in-game",
            *REQUIRED,
            "- [ ] I've linked this PR to any related issues in the repo project",
        )
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PR description validation PASSED" in result.stdout


def test_in_game_line_with_agent_html_comment_still_optional():
    result = _run_validator(
        _body(
            "- [ ] I have tested these changes in-game <!-- Agents: leave unchecked. Humans mark this after Retail QA. -->",
            *REQUIRED,
        )
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_in_game_testing_checked_still_passes():
    result = _run_validator(
        _body(
            "- [x] I have tested these changes in-game",
            *REQUIRED,
        )
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_required_unchecked_item_is_still_a_failure():
    items = list(REQUIRED)
    items[0] = "- [ ] My code follows the project's style guidelines"
    result = _run_validator(_body("- [ ] I have tested these changes in-game", *items))
    assert result.returncode == 1
    assert "Not all checklist items are checked" in result.stdout
