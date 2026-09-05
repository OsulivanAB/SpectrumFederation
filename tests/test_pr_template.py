"""Tests for PR template validation, including human-owned checklist items."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

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


def _load_script(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS_DIR / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _load_validator():
    return _load_script("validate_pr_template")


validate_pr_template = _load_validator()


def _body(*checklist_items: str) -> str:
    return (
        "## Type of Change\n\n- [x] New feature\n\n## Checklist\n\n"
        + "\n".join(checklist_items)
        + "\n"
    )


def _run_validator(
    body: str,
    *,
    changed_files: str | None = "",
    toc_diff: str | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PR_BODY"] = body
    env.pop("PR_CHANGED_FILES_PATH", None)
    env.pop("PR_TOC_DIFF_PATH", None)
    env.pop("PR_BASE_SHA", None)
    env.pop("PR_HEAD_SHA", None)
    if changed_files is None:
        env.pop("PR_CHANGED_FILES", None)
    else:
        env["PR_CHANGED_FILES"] = changed_files
    if toc_diff is None:
        env.pop("PR_TOC_DIFF", None)
    else:
        env["PR_TOC_DIFF"] = toc_diff
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
    assert "cannot be selected when packaged addon files changed" in result.stdout
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


def test_packaged_addon_path_uses_package_membership_not_extension():
    packaging = _load_script("validate_packaging")
    assert list(validate_pr_template.NON_PACKAGED_ADDON_GLOBS) == packaging.ZIP_EXCLUDES

    assert validate_pr_template.is_packaged_addon_path("SpectrumFederation/modules/core.lua")
    assert validate_pr_template.is_packaged_addon_path(
        "SpectrumFederation_CursedSurgeTracker/Tracker.lua"
    )
    assert validate_pr_template.is_packaged_addon_path("SpectrumFederation/locale/enUS.lua")
    assert validate_pr_template.is_packaged_addon_path("SpectrumFederation/Foo.xml")
    assert validate_pr_template.is_packaged_addon_path(
        "SpectrumFederation/media/Icons/SpectrumFederationIcon.tga"
    )
    assert validate_pr_template.is_packaged_addon_path(
        "SpectrumFederation_CursedSurgeTracker/media/ring.png"
    )
    assert validate_pr_template.is_packaged_addon_path(
        "SpectrumFederation/some_future_asset.xyz"
    )
    assert validate_pr_template.is_packaged_addon_path(
        "SpectrumFederation/SpectrumFederation.toc"
    )
    assert not validate_pr_template.is_packaged_addon_path(
        "SpectrumFederation/AGENTS.md"
    )
    assert validate_pr_template.is_explicitly_non_runtime_packaged_exception(
        "SpectrumFederation/AGENTS.md"
    )
    assert not validate_pr_template.is_packaged_addon_path(
        ".github/scripts/publish_release.py"
    )
    assert not validate_pr_template.is_packaged_addon_path("docs/development/automation.md")
    assert validate_pr_template.is_addon_toc_path("SpectrumFederation/SpectrumFederation.toc")
    assert validate_pr_template.is_addon_toc_path(
        "SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc"
    )
    assert not validate_pr_template.is_addon_toc_path("docs/example.toc")


NA_BODY = _body(
    "- [ ] I have tested these changes in-game",
    "- [x] In-game testing is not applicable to this change",
    *REQUIRED,
)

PR267_PARENT_TOC_DIFF = """diff --git a/SpectrumFederation/SpectrumFederation.toc b/SpectrumFederation/SpectrumFederation.toc
index 6686745..880e79e 100644
--- a/SpectrumFederation/SpectrumFederation.toc
+++ b/SpectrumFederation/SpectrumFederation.toc
@@ -1,11 +1,12 @@
 ## Interface: 120100
 ## Title: Spectrum Federation
 ## Author: OsulivanAB
-## Version: 1.4.0-beta.6
+## Version: 1.4.0-beta.7
 ## Notes: Loot profile management and helper tools for guild coordination.
 ## X-Website: https://github.com/OsulivanAB/SpectrumFederation
 ## X-Documentation: https://osullivanab.github.io/SpectrumFederation/
+## X-Wago-ID: BNBmnlGx
 ## SavedVariables: SpectrumFederationDB, SpectrumFederationDebugDB
"""

PR267_CHILD_TOC_DIFF = """diff --git a/SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc b/SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc
index 90e243b..9cbc031 100644
--- a/SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc
+++ b/SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc
@@ -2,7 +2,7 @@
 ## Title: Spectrum Federation: Cursed Surge Tracker
 ## Author: OsulivanAB
-## Version: 1.4.0-beta.6
+## Version: 1.4.0-beta.7
 ## Dependencies: SpectrumFederation
"""

PR267_TOC_DIFF = PR267_PARENT_TOC_DIFF + PR267_CHILD_TOC_DIFF

PR267_CHANGED_FILES = (
    ".github/scripts/publish_release.py\n"
    "docs/development/automation.md\n"
    "SpectrumFederation/SpectrumFederation.toc\n"
    "SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc\n"
    "tests/test_publish_release.py"
)

PACKAGED_QA_PATHS = (
    "SpectrumFederation/modules/core.lua",
    "SpectrumFederation_CursedSurgeTracker/Tracker.lua",
    "SpectrumFederation/Foo.xml",
    "SpectrumFederation/media/Icons/SpectrumFederationIcon.tga",
    "SpectrumFederation/media/Textures/SpectrumFederationBanner.tga",
    "SpectrumFederation_CursedSurgeTracker/media/ring.png",
    "SpectrumFederation/some_future_asset.xyz",
    "SpectrumFederation/locale/enUS.lua",
    "SpectrumFederation/Libs/LibStub/LibStub.lua",
)


def test_na_rejected_for_packaged_addon_assets_and_unknown_types():
    for path in PACKAGED_QA_PATHS:
        result = _run_validator(NA_BODY, changed_files=path)
        assert result.returncode == 1, path
        assert "packaged addon files changed" in result.stdout
        assert path in result.stdout


def test_na_rejected_for_child_addon_tga_loophole():
    """A packaged texture must not qualify for in-game testing N/A."""
    result = _run_validator(
        NA_BODY,
        changed_files="SpectrumFederation_CursedSurgeTracker/media/ring.tga",
    )
    assert result.returncode == 1
    assert "packaged addon files changed" in result.stdout
    assert "SpectrumFederation_CursedSurgeTracker/media/ring.tga" in result.stdout


def test_na_rejected_for_added_or_deleted_packaged_asset():
    added = _run_validator(
        NA_BODY,
        changed_files="SpectrumFederation/media/Textures/NewBanner.tga",
    )
    deleted = _run_validator(
        NA_BODY,
        changed_files="SpectrumFederation_CursedSurgeTracker/media/ring.png",
    )
    assert added.returncode == 1
    assert deleted.returncode == 1
    assert "NewBanner.tga" in added.stdout
    assert "ring.png" in deleted.stdout


def test_na_allowed_for_repository_only_agents_md():
    result = _run_validator(NA_BODY, changed_files="SpectrumFederation/AGENTS.md")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "In-game testing is marked not applicable" in result.stdout


def _toc_diff(path, body):
    return (
        f"diff --git a/{path} b/{path}\n"
        f"--- a/{path}\n"
        f"+++ b/{path}\n"
        "@@ -1,3 +1,3 @@\n"
        f"{body}"
    )


def test_na_allowed_for_version_only_toc_change():
    path = "SpectrumFederation/SpectrumFederation.toc"
    result = _run_validator(
        NA_BODY,
        changed_files=path,
        toc_diff=_toc_diff(
            path,
            "-## Version: 1.4.0-beta.6\n+## Version: 1.4.0-beta.7\n",
        ),
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_na_allowed_for_x_wago_id_only_toc_change():
    path = "SpectrumFederation/SpectrumFederation.toc"
    result = _run_validator(
        NA_BODY,
        changed_files=path,
        toc_diff=_toc_diff(path, "+## X-Wago-ID: BNBmnlGx\n"),
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_na_allowed_for_version_and_x_wago_id_toc_change():
    result = _run_validator(
        NA_BODY,
        changed_files="SpectrumFederation/SpectrumFederation.toc",
        toc_diff=PR267_PARENT_TOC_DIFF,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_na_allowed_for_infrastructure_plus_safe_toc_metadata():
    result = _run_validator(
        NA_BODY,
        changed_files=PR267_CHANGED_FILES,
        toc_diff=PR267_TOC_DIFF,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "In-game testing is marked not applicable" in result.stdout


def test_pr267_safe_toc_fixture_qualifies_for_na():
    parsed = validate_pr_template.get_changed_toc_lines(PR267_TOC_DIFF)
    reasons = validate_pr_template.toc_changes_require_in_game_testing(
        [
            "SpectrumFederation/SpectrumFederation.toc",
            "SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc",
        ],
        parsed,
    )
    assert reasons == []


@pytest.mark.parametrize(
    ("hunk", "needle"),
    [
        ("-## Interface: 120100\n+## Interface: 120105\n", "## interface"),
        ("-## Dependencies: SpectrumFederation\n+## Dependencies: SpectrumFederation, Other\n", "## dependencies"),
        ("-## SavedVariables: OldDB\n+## SavedVariables: NewDB\n", "## savedvariables"),
        (
            "-## SavedVariablesPerCharacter: OldCharDB\n+## SavedVariablesPerCharacter: NewCharDB\n",
            "## savedvariablespercharacter",
        ),
        ("-## LoadOnDemand: 0\n+## LoadOnDemand: 1\n", "## loadondemand"),
        ("+modules/NewThing.lua\n", "file-list/load-order"),
        ("-modules/OldThing.lua\n", "file-list/load-order"),
        ("-modules/A.lua\n+modules/B.lua\n", "file-list/load-order"),
        ("+## Title: Changed Title\n", "unallowlisted"),
        ("+## Definitely-Not-A-Real-Field: 1\n", "unallowlisted"),
    ],
)
def test_na_rejected_for_runtime_or_unknown_toc_change(hunk, needle):
    path = "SpectrumFederation/SpectrumFederation.toc"
    result = _run_validator(
        NA_BODY,
        changed_files=path,
        toc_diff=_toc_diff(path, hunk),
    )
    assert result.returncode == 1
    assert "cannot be selected" in result.stdout
    assert needle in result.stdout.lower()


def test_na_rejected_for_malformed_toc_diff():
    result = _run_validator(
        NA_BODY,
        changed_files="SpectrumFederation/SpectrumFederation.toc",
        toc_diff="+## Version: 1.4.0-beta.7\nthis is not a unified diff\n",
    )
    assert result.returncode == 1
    assert "unavailable or malformed" in result.stdout


def test_na_rejected_when_toc_changed_but_diff_unavailable():
    result = _run_validator(
        NA_BODY,
        changed_files="SpectrumFederation/SpectrumFederation.toc",
    )
    assert result.returncode == 1
    assert "unavailable or malformed" in result.stdout


def test_classify_toc_line_allowlist_and_runtime_fields():
    assert validate_pr_template.classify_toc_line("## Version: 1.4.0-beta.7") == (
        "safe",
        "version",
    )
    assert validate_pr_template.classify_toc_line("## X-Wago-ID: BNBmnlGx") == (
        "safe",
        "x-wago-id",
    )
    assert validate_pr_template.classify_toc_line("## Interface: 120100") == (
        "runtime",
        "interface",
    )
    assert validate_pr_template.classify_toc_line("modules/core.lua") == (
        "runtime",
        "file-list",
    )
    assert validate_pr_template.classify_toc_line("## Title: Spectrum Federation") == (
        "unknown",
        "title",
    )
    assert validate_pr_template.classify_toc_line("# --- Modules ---") == (
        "safe",
        "comment",
    )
