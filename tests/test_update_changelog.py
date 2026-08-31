"""Deterministic tests for changelog range, validation, and write safety."""

from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / ".github" / "scripts" / "update_changelog.py"
SPEC = importlib.util.spec_from_file_location("update_changelog", MODULE_PATH)
changelog = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(changelog)


SAMPLE_CHANGELOG = """# Changelog

All notable changes to SpectrumFederation will be documented in this file.

## [1.3.0-beta.2] - 2026-08-27

### Added
- Added Cursed Surge Tracker child addon

### Fixed
- Fixed Cursed Surge Tracker pin scheduling

## [1.3.0-beta.1] - 2026-08-26

### Added
- Added Cursed Surge Tracker child addon

## [1.2.0] - 2026-08-26

### Added
- Added the `/sf version` raid roster window

## [1.1.0] - 2026-08-21

### Changed
- Infrastructure and tooling updates (no addon code changes)
"""


def git(repo, *args):
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )


def init_repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    (repo / "SpectrumFederation").mkdir()
    (repo / "SpectrumFederation" / "SpectrumFederation.toc").write_text(
        "## Version: 1.2.0\n",
        encoding="utf-8",
    )
    (repo / "CHANGELOG.md").write_text(SAMPLE_CHANGELOG, encoding="utf-8")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "chore: promote beta to main [skip ci]")
    git(repo, "tag", "v1.2.0")
    return repo


def test_parse_and_strip_beta_sections_preserves_stable_history():
    preface, sections = changelog.parse_changelog_sections(SAMPLE_CHANGELOG)
    assert preface.startswith("# Changelog")
    assert [section["version"] for section in sections] == [
        "1.3.0-beta.2",
        "1.3.0-beta.1",
        "1.2.0",
        "1.1.0",
    ]
    cleaned, removed = changelog.strip_beta_sections(
        SAMPLE_CHANGELOG,
        keep_other_trains=False,
        current_version="1.3.0",
    )
    assert removed == ["## [1.3.0-beta.2] - 2026-08-27", "## [1.3.0-beta.1] - 2026-08-26"]
    assert "## [1.2.0]" in cleaned
    assert "## [1.1.0]" in cleaned
    assert "1.3.0-beta" not in cleaned
    assert "Added the `/sf version` raid roster window" in cleaned


def test_beta_sections_only_include_current_release_train():
    _preface, sections = changelog.parse_changelog_sections(SAMPLE_CHANGELOG)
    matched = changelog.beta_sections_for_train(sections, "1.3.0")
    assert [section["version"] for section in matched] == ["1.3.0-beta.2", "1.3.0-beta.1"]


def test_classify_changed_files_separates_user_facing_and_internal():
    user_facing, internal = changelog.classify_changed_files(
        [
            "SpectrumFederation/modules/RaidCheck.lua",
            "SpectrumFederation/SpectrumFederation.toc",
            "SpectrumFederation_CursedSurgeTracker/Tracker.lua",
            ".github/workflows/post-merge-beta.yml",
            "docs/development/automation.md",
            "tests/test_update_changelog.py",
        ]
    )
    assert user_facing == [
        "SpectrumFederation/modules/RaidCheck.lua",
        "SpectrumFederation_CursedSurgeTracker/Tracker.lua",
    ]
    assert "SpectrumFederation/SpectrumFederation.toc" in internal
    assert ".github/workflows/post-merge-beta.yml" in internal


def test_validate_ai_payload_rejects_ungrounded_and_placeholder_entries():
    context = {
        "user_facing_files": ["SpectrumFederation_CursedSurgeTracker/Tracker.lua"],
        "commits": [{"subject": "feat: add Cursed Surge Tracker", "body": ""}],
        "pull_requests": [],
        "beta_sections": [],
        "diff": {"stat": "Tracker.lua", "name_status": "A\tTracker.lua"},
    }
    accepted, error = changelog.validate_ai_payload(
        {
            "confidence": "high",
            "skip": False,
            "entries": [
                {
                    "category": "Added",
                    "text": "Added the Cursed Surge Tracker child addon for The Coiled Isle.",
                }
            ],
        },
        context,
    )
    assert error is None
    assert accepted[0]["category"] == "Added"

    _rejected, placeholder_error = changelog.validate_ai_payload(
        {
            "confidence": "high",
            "entries": [
                {
                    "category": "Changed",
                    "text": "Infrastructure and tooling updates (no addon code changes)",
                }
            ],
        },
        context,
    )
    assert placeholder_error

    _rejected, grounded_error = changelog.validate_ai_payload(
        {
            "confidence": "high",
            "entries": [
                {"category": "Added", "text": "Added a teleport network and auction house."}
            ],
        },
        context,
    )
    assert grounded_error and "ungrounded" in grounded_error

    _rejected, low_confidence = changelog.validate_ai_payload(
        {"confidence": "low", "entries": [{"category": "Added", "text": "Added Cursed Surge Tracker"}]},
        context,
    )
    assert low_confidence


def test_replace_or_insert_is_idempotent_for_existing_real_section():
    rendered = changelog.render_section(
        "1.3.0",
        "2026-08-30",
        [{"category": "Added", "text": "Added Cursed Surge Tracker"}],
    )
    first, changed = changelog.replace_or_insert_section(SAMPLE_CHANGELOG, "1.3.0", rendered)
    assert changed
    assert first.count("## [1.3.0] - 2026-08-30") == 1
    assert "## [1.2.0]" in first

    second, changed_again = changelog.replace_or_insert_section(first, "1.3.0", rendered)
    assert changed_again is False
    assert second == first


def test_extract_bullets_joins_wrapped_merge_message_lines():
    bullets = changelog.extract_bullets(
        """### Added
- Merge pull request #253 from OsulivanAB/cursor/cursed-surge-tracker-8250

Add Spectrum Federation: Cursed Surge Tracker child addon
"""
    )
    assert bullets == [
        (
            "Added",
            "Merge pull request #253 from OsulivanAB/cursor/cursed-surge-tracker-8250 Add Spectrum Federation: Cursed Surge Tracker child addon",
        )
    ]
    cleaned = changelog.normalize_bullet_text(bullets[0][1])
    assert cleaned == "Add Spectrum Federation: Cursed Surge Tracker child addon"


def test_fallback_promotes_related_beta_notes_and_drops_reverted_features():
    context = {
        "mode": "promote",
        "features": ["Cursed Surge Tracker"],
        "beta_sections": [
            {
                "text": """## [1.3.0-beta.2]
### Added
- Merge pull request #253 from OsulivanAB/cursor/cursed-surge-tracker-8250

Add Spectrum Federation: Cursed Surge Tracker child addon
### Fixed
- Fixed Cursed Surge Tracker pin scheduling
### Changed
- Added Reward Pot loot mode
"""
            }
        ],
        "pull_requests": [],
        "commits": [],
    }
    entries = changelog.fallback_entries(context)
    texts = [entry["text"] for entry in entries]
    assert any("Cursed Surge Tracker" in text for text in texts)
    assert all("Reward Pot" not in text for text in texts)
    assert len([entry for entry in entries if "Cursed Surge Tracker" in entry["text"]]) == 1


def test_fallback_does_not_invent_overlapping_path_features():
    context = {
        "mode": "promote",
        "features": ["Reward Pot", "Loot Helper", "Raid Check", "Settings"],
        "beta_sections": [
            {
                "text": """### Added
- Add Reward Pot loot mode alongside Point Based
"""
            }
        ],
        "pull_requests": [],
        "commits": [],
    }
    entries = changelog.fallback_entries(context)
    assert [entry["text"] for entry in entries] == [
        "Add Reward Pot loot mode alongside Point Based"
    ]


def test_fallback_keeps_unrelated_features_separate():
    context = {
        "mode": "promote",
        "features": ["Cursed Surge Tracker", "Version Check"],
        "beta_sections": [
            {
                "text": """### Added
- Added Cursed Surge Tracker child addon
- Added the /sf version raid roster window
"""
            }
        ],
        "pull_requests": [],
        "commits": [],
    }
    entries = changelog.fallback_entries(context)
    assert len(entries) == 2


def test_fallback_drops_catalog_notes_when_net_features_are_empty():
    context = {
        "mode": "promote",
        "features": [],
        "user_facing_files": [],
        "beta_sections": [
            {
                "text": """### Added
- Added Cursed Surge Tracker child addon
"""
            }
        ],
        "pull_requests": [],
        "commits": [],
    }
    assert changelog.fallback_entries(context) == []


def test_fallback_drops_reverted_catalog_notes_when_only_uncataloged_files_remain():
    context = {
        "mode": "promote",
        "features": [],
        "user_facing_files": ["SpectrumFederation/modules/core.lua"],
        "beta_sections": [
            {
                "text": """### Added
- Added Cursed Surge Tracker child addon
- Tweaked core login initialization
"""
            }
        ],
        "pull_requests": [],
        "commits": [],
    }
    entries = changelog.fallback_entries(context)
    texts = [entry["text"] for entry in entries]
    assert all("Cursed Surge Tracker" not in text for text in texts)
    assert any("core login" in text.lower() for text in texts)


def test_promote_skip_still_strips_beta_sections(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    monkeypatch.chdir(repo)
    context = {
        "mode": "promote",
        "version": "1.3.0",
        "changelog_text": SAMPLE_CHANGELOG,
    }
    cleaned, removed = changelog.strip_promoted_beta_sections(context)
    assert removed
    assert "1.3.0-beta" not in cleaned
    assert "## [1.2.0]" in cleaned
    assert "## [1.1.0]" in cleaned
    assert context["changelog_text"] == cleaned


def test_choose_entries_skips_internal_only_and_existing_sections():
    existing_context = {
        "version": "1.3.0-beta.2",
        "existing_section": {"text": "## [1.3.0-beta.2]\n\n### Added\n- Added Cursed Surge Tracker"},
        "user_facing_files": ["SpectrumFederation_CursedSurgeTracker/Tracker.lua"],
        "beta_sections": [],
    }
    assert changelog.choose_entries(existing_context, token=None) is None

    internal_only = {
        "version": "1.3.0-beta.3",
        "existing_section": None,
        "user_facing_files": [],
        "beta_sections": [],
    }
    assert changelog.choose_entries(internal_only, token=None) is None


def test_promote_range_uses_previous_stable_tag(tmp_path, monkeypatch):
    repo = init_repo(tmp_path)
    (repo / "SpectrumFederation_CursedSurgeTracker").mkdir()
    (repo / "SpectrumFederation_CursedSurgeTracker" / "Tracker.lua").write_text(
        "return true\n",
        encoding="utf-8",
    )
    (repo / "SpectrumFederation" / "SpectrumFederation.toc").write_text(
        "## Version: 1.3.0-beta.2\n",
        encoding="utf-8",
    )
    git(repo, "add", ".")
    git(repo, "commit", "-m", "feat: add Cursed Surge Tracker")
    git(repo, "commit", "--allow-empty", "-m", "chore: promote beta to main [skip ci]")
    git(repo, "commit", "--allow-empty", "-m", "chore: update version to 1.3.0 [skip ci]")
    git(repo, "commit", "--allow-empty", "-m", "docs: update badges for 1.3.0 [skip ci]")

    monkeypatch.chdir(repo)
    resolved = changelog.resolve_range("promote", version="1.3.0")
    files = changelog.list_changed_files(resolved["base"], resolved["head"])
    assert "SpectrumFederation_CursedSurgeTracker/Tracker.lua" in files
    commits = changelog.list_commits(resolved["base"], resolved["head"])
    subjects = [commit["subject"] for commit in commits]
    assert "feat: add Cursed Surge Tracker" in subjects
    assert all(not subject.startswith("docs: update badges") for subject in subjects)


def test_beta_range_peels_automation_and_uses_merge_parent(tmp_path, monkeypatch):
    repo = init_repo(tmp_path)
    git(repo, "checkout", "-b", "feature")
    (repo / "SpectrumFederation" / "RaidCheck.lua").write_text("print('raid')\n", encoding="utf-8")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "fix: keep Raid Check whispers separate")
    git(repo, "checkout", "-")
    git(repo, "merge", "--no-ff", "-m", "Merge pull request #246 from user/raid-check", "feature")
    git(repo, "commit", "--allow-empty", "-m", "docs: update changelog for 1.3.0-beta.2 [skip ci]")

    monkeypatch.chdir(repo)
    resolved = changelog.resolve_range("beta")
    files = changelog.list_changed_files(resolved["base"], resolved["head"])
    assert "SpectrumFederation/RaidCheck.lua" in files
    commits = changelog.list_commits(resolved["base"], resolved["head"])
    assert any("Raid Check" in commit["subject"] for commit in commits)


def test_rerun_does_not_replace_existing_equivalent_section(tmp_path, monkeypatch):
    repo = init_repo(tmp_path)
    monkeypatch.chdir(repo)
    context = {
        "mode": "beta",
        "version": "1.3.0-beta.2",
        "changelog_text": SAMPLE_CHANGELOG,
        "existing_section": {"text": "## [1.3.0-beta.2]\n\n### Added\n- Added Cursed Surge Tracker child addon"},
    }
    changed = changelog.apply_changelog(
        context,
        [{"category": "Added", "text": "Added a duplicate Cursed Surge Tracker line"}],
        "2026-08-30",
    )
    assert changed is False
    written = (repo / "CHANGELOG.md").read_text(encoding="utf-8")
    assert written == SAMPLE_CHANGELOG


def test_prompt_truncation_keeps_json_schema():
    context = {
        "mode": "promote",
        "version": "1.3.0",
        "range": {"label": "v1.2.0...HEAD"},
        "user_facing_files": ["SpectrumFederation_CursedSurgeTracker/Tracker.lua"],
        "commits": [],
        "pull_requests": [],
        "beta_sections": [],
        "previous_stable_section": "",
        "diff": {
            "stat": "ok",
            "name_status": "A\tTracker.lua",
            "patch": "x" * 40000,
        },
    }
    prompt = changelog.build_prompt(context)
    assert "Respond with JSON only" in prompt
    assert '"confidence"' in prompt
    assert len(prompt) <= changelog.MAX_PROMPT_CHARS + 80


def test_ambiguous_ai_output_does_not_write_when_fallback_is_empty(monkeypatch):
    context = {
        "version": "1.4.0-beta.1",
        "mode": "beta",
        "existing_section": None,
        "user_facing_files": ["SpectrumFederation/modules/Core.lua"],
        "beta_sections": [],
        "features": [],
        "commits": [],
        "pull_requests": [],
        "diff": {"stat": "", "name_status": "", "patch": ""},
    }
    monkeypatch.setattr(changelog, "request_ai_entries", lambda _context, _token: (None, "model confidence was 'low'"))
    monkeypatch.setattr(changelog, "fallback_entries", lambda _context: [])
    assert changelog.choose_entries(context, token=None) is None
