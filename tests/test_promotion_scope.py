"""Tests for deterministic promotion-scope classification."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / ".github" / "scripts"


def _load_script(name):
    module_path = SCRIPTS_DIR / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


scope_mod = _load_script("classify_promotion_scope")
packaging = _load_script("validate_packaging")


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
    git(repo, "init", "-b", "main")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    (repo / "SpectrumFederation").mkdir()
    (repo / "SpectrumFederation" / "Core").mkdir()
    (repo / "SpectrumFederation" / "SpectrumFederation.toc").write_text(
        "## Version: 1.4.1\n",
        encoding="utf-8",
    )
    (repo / "SpectrumFederation" / "AGENTS.md").write_text("addon notes\n", encoding="utf-8")
    (repo / "docs").mkdir()
    (repo / "docs" / "index.md").write_text("# Docs\n", encoding="utf-8")
    (repo / "overrides").mkdir()
    (repo / "overrides" / "main.html").write_text("<div></div>\n", encoding="utf-8")
    (repo / "mkdocs.yml").write_text("site_name: Test\n", encoding="utf-8")
    (repo / "README.md").write_text("# README\n", encoding="utf-8")
    (repo / "CHANGELOG.md").write_text("# Changelog\n", encoding="utf-8")
    (repo / ".github" / "workflows").mkdir(parents=True)
    (repo / ".github" / "workflows" / "promote-beta-to-main.yml").write_text(
        "name: promote\n",
        encoding="utf-8",
    )
    git(repo, "add", ".")
    git(repo, "commit", "-m", "initial main")
    git(repo, "checkout", "-b", "beta")
    return repo


def commit_files(repo, mapping, message):
    for relative, content in mapping.items():
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    git(repo, "add", *mapping.keys())
    git(repo, "commit", "-m", message)


def flags(scope):
    return {
        "addon_changed": scope.addon_changed,
        "docs_changed": scope.docs_changed,
        "readme_changed": scope.readme_changed,
        "changelog_changed": scope.changelog_changed,
        "infra_changed": scope.infra_changed,
        "release_required": scope.release_required,
        "changelog_required": scope.changelog_required,
        "documentation_deploy_required": scope.documentation_deploy_required,
        "readme_work_required": scope.readme_work_required,
    }


def test_packaged_roots_match_release_zip_membership():
    assert "SpectrumFederation" in scope_mod.ADDON_ROOTS
    assert "SpectrumFederation_CursedSurgeTracker" in scope_mod.ADDON_ROOTS
    assert "SpectrumFederation_RCLootCouncilIntegration" in scope_mod.ADDON_ROOTS
    assert tuple(scope_mod.ZIP_EXCLUDES) == tuple(packaging.ZIP_EXCLUDES)


def test_case_a_documentation_only():
    scope = scope_mod.classify_files(["docs/foo.md"])
    assert flags(scope) == {
        "addon_changed": False,
        "docs_changed": True,
        "readme_changed": False,
        "changelog_changed": False,
        "infra_changed": False,
        "release_required": False,
        "changelog_required": False,
        "documentation_deploy_required": True,
        "readme_work_required": False,
    }


def test_case_h_observed_docs_only_promotion_paths():
    scope = scope_mod.classify_files(
        [
            "docs/assets/SpectrumFederationBannerV2.jpg",
            "docs/assets/curseforge.png",
            "docs/assets/wowup.png",
            "docs/getting-started.md",
            "docs/index.md",
            "docs/stylesheets/extra.css",
        ]
    )
    assert scope.addon_changed is False
    assert scope.docs_changed is True
    assert scope.release_required is False
    assert scope.documentation_deploy_required is True
    assert scope.changelog_required is False
    assert scope.readme_work_required is False


def test_mkdocs_config_and_theme_overrides_count_as_docs():
    scope = scope_mod.classify_files(
        ["mkdocs.yml", "overrides/main.html", "requirements-docs.txt"]
    )
    assert scope.docs_changed is True
    assert scope.documentation_deploy_required is True
    assert scope.addon_changed is False
    assert scope.release_required is False


def test_case_b_addon_only():
    scope = scope_mod.classify_files(["SpectrumFederation/Core/Foo.lua"])
    assert flags(scope) == {
        "addon_changed": True,
        "docs_changed": False,
        "readme_changed": False,
        "changelog_changed": False,
        "infra_changed": False,
        "release_required": True,
        "changelog_required": True,
        "documentation_deploy_required": False,
        "readme_work_required": True,
    }


def test_child_addons_are_packaged_release_changes():
    scope = scope_mod.classify_files(
        [
            "SpectrumFederation_CursedSurgeTracker/Tracker.lua",
            "SpectrumFederation_RCLootCouncilIntegration/Integration.lua",
        ]
    )
    assert scope.addon_changed is True
    assert scope.release_required is True
    assert scope.docs_changed is False


def test_case_c_addon_and_documentation_are_independent_flags():
    scope = scope_mod.classify_files(
        ["SpectrumFederation/modules/core.lua", "docs/index.md"]
    )
    assert scope.addon_changed is True
    assert scope.docs_changed is True
    assert scope.release_required is True
    assert scope.documentation_deploy_required is True
    assert scope.promotion_type == "addon + documentation"


def test_case_d_workflow_infrastructure_only():
    scope = scope_mod.classify_files([".github/workflows/example.yml"])
    assert flags(scope) == {
        "addon_changed": False,
        "docs_changed": False,
        "readme_changed": False,
        "changelog_changed": False,
        "infra_changed": True,
        "release_required": False,
        "changelog_required": False,
        "documentation_deploy_required": False,
        "readme_work_required": False,
    }


def test_agents_md_inside_addon_tree_is_not_a_release():
    scope = scope_mod.classify_files(["SpectrumFederation/AGENTS.md"])
    assert scope.addon_changed is False
    assert scope.release_required is False
    assert scope.infra_changed is True
    assert scope.documentation_deploy_required is False


def test_case_e_readme_only_does_not_publish_or_deploy_docs():
    scope = scope_mod.classify_files(["README.md"])
    assert flags(scope) == {
        "addon_changed": False,
        "docs_changed": False,
        "readme_changed": True,
        "changelog_changed": False,
        "infra_changed": False,
        "release_required": False,
        "changelog_required": False,
        "documentation_deploy_required": False,
        "readme_work_required": True,
    }


def test_case_f_generated_changelog_does_not_create_a_release():
    incoming = scope_mod.classify_files(["SpectrumFederation/modules/core.lua"])
    generated = scope_mod.classify_files(["CHANGELOG.md"])
    assert incoming.release_required is True
    assert generated.addon_changed is False
    assert generated.release_required is False
    assert generated.changelog_changed is True
    assert generated.changelog_required is False


def test_case_g_generated_readme_does_not_create_a_release():
    incoming = scope_mod.classify_files(["SpectrumFederation/modules/core.lua"])
    generated = scope_mod.classify_files(["README.md"])
    assert incoming.release_required is True
    assert incoming.readme_work_required is True
    assert generated.release_required is False
    assert generated.addon_changed is False
    assert generated.readme_work_required is True


def test_incoming_changelog_only_does_not_require_generation():
    scope = scope_mod.classify_files(["CHANGELOG.md"])
    assert scope.changelog_changed is True
    assert scope.changelog_required is False
    assert scope.release_required is False


def test_no_downstream_changes():
    scope = scope_mod.classify_files([])
    assert scope.has_incoming_changes is False
    assert scope.release_required is False
    assert scope.documentation_deploy_required is False
    assert scope.readme_work_required is False
    assert scope.promotion_type == "No downstream-relevant changes"


def test_git_range_uses_merge_base_not_double_dot(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# Updated docs\n"}, "docs: update index")
    git(repo, "checkout", "main")
    commit_files(
        repo,
        {".github/workflows/promote-beta-to-main.yml": "name: later main\n"},
        "ci: change already on main",
    )
    git(repo, "checkout", "beta")

    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.docs_changed is True
    assert scope.documentation_deploy_required is True
    assert scope.addon_changed is False
    assert scope.release_required is False
    assert ".github/workflows/promote-beta-to-main.yml" not in scope.files
    assert scope.promotion_base_sha
    assert scope.promotion_target_sha
    assert scope.promotion_merge_base_sha
    assert scope.promotion_base_sha != scope.promotion_target_sha


def test_git_range_does_not_treat_later_generated_commits_as_incoming(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {"SpectrumFederation/Core/Foo.lua": "print('feature')\n"},
        "feat: addon change",
    )
    incoming = scope_mod.classify_git_range("main", "HEAD", cwd=repo)
    assert incoming.addon_changed is True
    assert incoming.release_required is True

    commit_files(repo, {"CHANGELOG.md": "# Changelog\n\n## generated\n"}, "docs: update changelog")
    commit_files(repo, {"README.md": "# README badges\n"}, "docs: update badges")

    generated_only = scope_mod.classify_files(["CHANGELOG.md", "README.md"])
    assert generated_only.release_required is False
    assert generated_only.addon_changed is False

    # Classification of the original promotion range stays addon-only when
    # the captured target SHA is the incoming commit, not later automation.
    original_target = incoming.promotion_target_sha
    rerun = scope_mod.classify_git_range("main", original_target, cwd=repo)
    assert rerun.addon_changed is True
    assert rerun.changelog_changed is False
    assert rerun.readme_changed is False
    assert rerun.files == incoming.files


def test_write_github_output_uses_true_false_strings(tmp_path):
    output_path = tmp_path / "output"
    output_path.write_text("", encoding="utf-8")
    scope = scope_mod.classify_files(["docs/index.md"])
    scope_mod.write_github_output(scope, output_path)
    text = output_path.read_text(encoding="utf-8")
    assert "addon_changed=false\n" in text
    assert "docs_changed=true\n" in text
    assert "documentation_deploy_required=true\n" in text
    assert "release_required=false\n" in text
    assert "changelog_required=false\n" in text


def test_job_outcome_ok_fails_closed_when_required_job_is_skipped():
    assert scope_mod.job_outcome_ok(True, "success") is True
    assert scope_mod.job_outcome_ok(True, "skipped") is False
    assert scope_mod.job_outcome_ok(False, "skipped") is True
    assert scope_mod.job_outcome_ok(False, "success") is True
    assert scope_mod.job_outcome_ok(False, "failure") is False
    assert scope_mod.job_outcome_ok(True, "failure") is False


def test_verify_promotion_outcomes_catches_skipped_docs_deploy():
    errors = scope_mod.verify_promotion_outcomes(
        [
            ("Merge Beta to Main", True, "success"),
            ("Deploy Documentation", True, "skipped"),
            ("Publish Stable Release", False, "skipped"),
            ("Fast-Forward Beta to Main", True, "skipped"),
        ]
    )
    assert "Deploy Documentation was required but result was 'skipped'" in errors
    assert "Fast-Forward Beta to Main was required but result was 'skipped'" in errors
    assert not any("Publish Stable Release" in error for error in errors)


def test_docs_only_expected_outcomes_pass_verification():
    errors = scope_mod.verify_promotion_outcomes(
        [
            ("Merge Beta to Main", True, "success"),
            ("Update Changelog for Main", False, "skipped"),
            ("Update README for Main", False, "skipped"),
            ("Deploy Documentation", True, "success"),
            ("Publish Stable Release", False, "skipped"),
            ("Fast-Forward Beta to Main", True, "success"),
        ]
    )
    assert errors == []


def test_cli_files_mode_prints_scope_report(capsys):
    exit_code = scope_mod.main(["--files", "docs/foo.md"])
    captured = capsys.readouterr()
    assert exit_code == 0
    assert "Documentation changes:      Yes" in captured.out
    assert "Stable addon release:       No" in captured.out
    assert "Documentation deployment:   Yes" in captured.out


def test_cli_rejects_mixed_git_and_file_modes():
    with pytest.raises(SystemExit):
        scope_mod.main(["--files", "docs/foo.md", "--base", "main", "--head", "beta"])
