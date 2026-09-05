"""Tests for PR template validation, including human-owned checklist items."""

from __future__ import annotations

import importlib.util
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


def _load_validator():
    spec = importlib.util.spec_from_file_location("validate_pr_template", VALIDATOR)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


validate_pr_template = _load_validator()


def _body(*checklist_items: str) -> str:
    return (
        "## Type of Change\n\n- [x] New feature\n\n## Checklist\n\n"
        + "\n".join(checklist_items)
        + "\n"
    )


def _run_validator(body: str, *, changed_files: str | None = "") -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PR_BODY"] = body
    env.pop("PR_CHANGED_FILES_PATH", None)
    env.pop("PR_BASE_SHA", None)
    env.pop("PR_HEAD_SHA", None)
    if changed_files is None:
        env.pop("PR_CHANGED_FILES", None)
    else:
        env["PR_CHANGED_FILES"] = changed_files
    return subprocess.run(
        [sys.executable, str(VALIDATOR)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_in_game_testing_unchecked_fails_validation():
    result = _run_validator(
        _body(
            "- [ ] I have tested these changes in-game",
            "- [ ] In-game testing is not applicable to this change",
            *REQUIRED,
            "- [ ] I've linked this PR to any related issues in the repo project",
        )
    )
    assert result.returncode == 1
    assert "exactly one in-game testing state" in result.stdout


def test_in_game_line_with_agent_html_comment_unchecked_still_fails():
    result = _run_validator(
        _body(
            "- [ ] I have tested these changes in-game <!-- Agents: leave unchecked. Humans mark this after Retail QA. -->",
            "- [ ] In-game testing is not applicable to this change",
            *REQUIRED,
        )
    )
    assert result.returncode == 1
    assert "exactly one in-game testing state" in result.stdout


def test_in_game_testing_checked_passes():
    result = _run_validator(
        _body(
            "- [x] I have tested these changes in-game",
            "- [ ] In-game testing is not applicable to this change",
            *REQUIRED,
        ),
        changed_files="SpectrumFederation/modules/core.lua",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PR description validation PASSED" in result.stdout
    assert "In-game testing is marked complete" in result.stdout


def test_in_game_na_passes_for_infrastructure_only_changes():
    result = _run_validator(
        _body(
            "- [ ] I have tested these changes in-game",
            "- [x] In-game testing is not applicable to this change",
            *REQUIRED,
        ),
        changed_files=(
            ".github/scripts/publish_release.py\n"
            "docs/development/automation.md\n"
            "SpectrumFederation/SpectrumFederation.toc\n"
            "tests/test_publish_release.py"
        ),
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "In-game testing is marked not applicable" in result.stdout


def test_in_game_na_rejected_when_addon_lua_changed():
    result = _run_validator(
        _body(
            "- [ ] I have tested these changes in-game",
            "- [x] In-game testing is not applicable to this change",
            *REQUIRED,
        ),
        changed_files="SpectrumFederation/modules/core.lua\n.github/scripts/publish_release.py",
    )
    assert result.returncode == 1
    assert "cannot be selected when addon Lua/XML runtime files changed" in result.stdout
    assert "SpectrumFederation/modules/core.lua" in result.stdout


def test_both_in_game_states_checked_fails():
    result = _run_validator(
        _body(
            "- [x] I have tested these changes in-game",
            "- [x] In-game testing is not applicable to this change",
            *REQUIRED,
        ),
        changed_files=".github/scripts/publish_release.py",
    )
    assert result.returncode == 1
    assert "not both" in result.stdout


def test_in_game_na_without_changed_file_list_fails_closed():
    result = _run_validator(
        _body(
            "- [ ] I have tested these changes in-game",
            "- [x] In-game testing is not applicable to this change",
            *REQUIRED,
        ),
        changed_files=None,
    )
    assert result.returncode == 1
    assert "requires a changed-file list" in result.stdout


def test_linked_issues_unchecked_is_still_optional():
    result = _run_validator(
        _body(
            "- [x] I have tested these changes in-game",
            "- [ ] In-game testing is not applicable to this change",
            *REQUIRED,
            "- [ ] I've linked this PR to any related issues in the repo project",
        )
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_required_unchecked_item_is_still_a_failure():
    items = list(REQUIRED)
    items[0] = "- [ ] My code follows the project's style guidelines"
    result = _run_validator(
        _body(
            "- [x] I have tested these changes in-game",
            "- [ ] In-game testing is not applicable to this change",
            *items,
        )
    )
    assert result.returncode == 1
    assert "Not all checklist items are checked" in result.stdout


def test_addon_runtime_path_detection():
    assert validate_pr_template.is_addon_runtime_path("SpectrumFederation/modules/core.lua")
    assert validate_pr_template.is_addon_runtime_path(
        "SpectrumFederation_CursedSurgeTracker/Tracker.lua"
    )
    assert validate_pr_template.is_addon_runtime_path("SpectrumFederation/locale/enUS.lua")
    assert validate_pr_template.is_addon_runtime_path("SpectrumFederation/Foo.xml")
    assert not validate_pr_template.is_addon_runtime_path(
        "SpectrumFederation/SpectrumFederation.toc"
    )
    assert not validate_pr_template.is_addon_runtime_path(
        ".github/scripts/publish_release.py"
    )
    assert not validate_pr_template.is_addon_runtime_path("docs/development/automation.md")
