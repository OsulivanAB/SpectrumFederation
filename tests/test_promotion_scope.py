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


PR282_GUIDANCE_PATHS = [
    "SpectrumFederation/AGENTS.md",
    "AGENTS.md",
    ".cursor/rules/addon-runtime.mdc",
    ".cursor/skills/pr-review-comments/SKILL.md",
    ".cursor/agents/repo-verifier.md",
    ".github/copilot-instructions.md",
    ".github/instructions/lua.instructions.md",
]


def test_pr282_style_guidance_set_does_not_require_release():
    scope = scope_mod.classify_files(PR282_GUIDANCE_PATHS)
    assert scope.addon_changed is False
    assert scope.release_required is False
    assert scope.changelog_required is False


def test_child_addon_agents_md_is_not_a_release():
    scope = scope_mod.classify_files(
        ["SpectrumFederation_CursedSurgeTracker/AGENTS.md"]
    )
    assert scope.addon_changed is False
    assert scope.release_required is False
    assert scope.infra_changed is True


def test_git_metadata_inside_addon_tree_is_not_a_release():
    scope = scope_mod.classify_files(["SpectrumFederation/.gitignore"])
    assert scope.addon_changed is False
    assert scope.release_required is False
    assert scope.infra_changed is True


def test_packaged_lua_plus_excluded_agents_still_requires_release():
    scope = scope_mod.classify_files(
        [
            "SpectrumFederation/modules/Foo.lua",
            "SpectrumFederation/AGENTS.md",
            "AGENTS.md",
        ]
    )
    assert scope.addon_changed is True
    assert scope.release_required is True
    assert "SpectrumFederation/modules/Foo.lua" in scope.addon_files
    assert "SpectrumFederation/AGENTS.md" in scope.infra_files


def test_parent_toc_change_is_a_packaged_release():
    scope = scope_mod.classify_files(
        ["SpectrumFederation/SpectrumFederation.toc"]
    )
    assert scope.addon_changed is True
    assert scope.release_required is True


def test_git_range_addon_agents_md_is_not_a_release(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {"SpectrumFederation/AGENTS.md": "# updated guidance\n"},
        "docs: addon agents guidance",
    )
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.addon_changed is False
    assert scope.release_required is False
    assert "SpectrumFederation/AGENTS.md" in scope.infra_files


def test_git_range_packaged_lua_requires_release_without_toc_change(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {"SpectrumFederation/modules/Foo.lua": "print('feat')\n"},
        "feat: runtime without toc bump",
    )
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.release_required is True
    assert not any(path.endswith(".toc") for path in scope.files)


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


def test_git_range_treats_rename_out_of_addon_tree_as_addon_and_docs(tmp_path):
    repo = init_repo(tmp_path)
    git(repo, "checkout", "main")
    commit_files(
        repo,
        {"SpectrumFederation/Core/Foo.lua": "print('feature')\n"},
        "feat: addon file",
    )
    git(repo, "checkout", "beta")
    git(repo, "merge", "main", "-m", "sync addon file onto beta")
    git(repo, "mv", "SpectrumFederation/Core/Foo.lua", "docs/Foo.lua")
    git(repo, "commit", "-m", "docs: move file into mkdocs")
    scope = scope_mod.classify_git_range("main", "HEAD", cwd=repo)
    assert "SpectrumFederation/Core/Foo.lua" in scope.files
    assert "docs/Foo.lua" in scope.files
    assert scope.addon_changed is True
    assert scope.docs_changed is True
    assert scope.release_required is True
    assert scope.documentation_deploy_required is True


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
    assert scope_mod.job_outcome_ok(False, "success") is False
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


def test_verify_promotion_outcomes_catches_unexpected_side_effect_success():
    errors = scope_mod.verify_promotion_outcomes(
        [
            ("Merge Beta to Main", True, "success"),
            ("Update Changelog for Main", False, "success"),
            ("Update README for Main", False, "success"),
            ("Deploy Documentation", False, "success"),
            ("Publish Stable Release", False, "success"),
            ("Fast-Forward Beta to Main", True, "success"),
        ]
    )
    assert "Update Changelog for Main was not required but ran with result 'success'" in errors
    assert "Update README for Main was not required but ran with result 'success'" in errors
    assert "Deploy Documentation was not required but ran with result 'success'" in errors
    assert "Publish Stable Release was not required but ran with result 'success'" in errors


def _captured_shas(repo):
    return (
        scope_mod.resolve_commit("main", cwd=repo),
        scope_mod.resolve_commit("beta", cwd=repo),
    )


def test_verify_promotion_refs_merge_accepts_unchanged_refs(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    assert scope_mod.verify_promotion_refs(
        base, target, "main", "beta", cwd=repo, mode="merge"
    ) == []


def test_verify_promotion_refs_merge_rejects_main_move(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    git(repo, "checkout", "main")
    commit_files(
        repo,
        {".github/workflows/promote-beta-to-main.yml": "name: later main\n"},
        "ci: main moved",
    )
    errors = scope_mod.verify_promotion_refs(
        base, target, "main", "beta", cwd=repo, mode="merge"
    )
    assert any("origin/main has moved" in error for error in errors)
    assert any("Rerun Promote Beta to Main" in error for error in errors)


def test_verify_promotion_refs_merge_rejects_beta_advance(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    commit_files(repo, {"docs/index.md": "# later beta\n"}, "docs: later beta")
    errors = scope_mod.verify_promotion_refs(
        base, target, "main", "beta", cwd=repo, mode="merge"
    )
    assert len(errors) == 1
    assert "origin/beta has advanced" in errors[0]
    assert "will not be promoted or overwritten" in errors[0]


def test_verify_promotion_refs_merge_rejects_beta_rewind(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    git(repo, "checkout", "beta")
    git(repo, "reset", "--hard", "main")
    errors = scope_mod.verify_promotion_refs(
        base, target, "main", "beta", cwd=repo, mode="merge"
    )
    assert any("rewound" in error for error in errors)


def test_verify_promotion_refs_merge_rejects_beta_diverge(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    git(repo, "checkout", "beta")
    git(repo, "reset", "--hard", "main")
    commit_files(repo, {"README.md": "# diverged\n"}, "docs: diverged beta")
    errors = scope_mod.verify_promotion_refs(
        base, target, "main", "beta", cwd=repo, mode="merge"
    )
    assert any("diverged" in error for error in errors)


def test_verify_promotion_refs_fast_forward_allows_main_to_move(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    git(repo, "checkout", "main")
    git(repo, "merge", "--no-ff", "beta", "-m", "promote")
    errors = scope_mod.verify_promotion_refs(
        base,
        target,
        "main",
        "beta",
        cwd=repo,
        mode="fast-forward",
        destination="main",
    )
    assert errors == []


def test_verify_promotion_refs_fast_forward_refuses_newer_beta(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    git(repo, "checkout", "main")
    git(repo, "merge", "--no-ff", "beta", "-m", "promote")
    git(repo, "checkout", "beta")
    commit_files(repo, {"docs/index.md": "# newer beta\n"}, "docs: newer beta")
    errors = scope_mod.verify_promotion_refs(
        base,
        target,
        "main",
        "beta",
        cwd=repo,
        mode="fast-forward",
        destination="main",
    )
    assert any("Refusing to overwrite newer beta work" in error for error in errors)


def test_verify_promotion_refs_fast_forward_requires_target_ancestor(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    errors = scope_mod.verify_promotion_refs(
        base,
        target,
        "main",
        "beta",
        cwd=repo,
        mode="fast-forward",
        destination="main",
    )
    assert any("is not an ancestor" in error for error in errors)


def test_cli_verify_refs_fails_on_beta_drift(tmp_path, monkeypatch, capsys):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    base, target = _captured_shas(repo)
    commit_files(repo, {"docs/index.md": "# later\n"}, "docs: later")
    monkeypatch.chdir(repo)
    exit_code = scope_mod.main(
        [
            "--verify-refs",
            "--expected-base",
            base,
            "--expected-target",
            target,
            "--current-base",
            "main",
            "--current-target",
            "beta",
            "--mode",
            "merge",
        ]
    )
    captured = capsys.readouterr()
    assert exit_code == 1
    assert "origin/beta has advanced" in captured.out
    assert "origin/beta has advanced" in captured.err


def test_promotion_workflow_pins_mutations_to_captured_shas():
    workflow = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "promote-beta-to-main.yml"
    text = workflow.read_text(encoding="utf-8")
    assert 'git merge -X ours --no-commit --no-ff "$EXPECTED_TARGET"' in text
    assert "git merge -X ours --no-commit --no-ff beta" not in text
    assert "git checkout beta --" not in text
    assert "git checkout origin/beta --" not in text
    assert "--force-with-lease" not in text
    assert "git push origin origin/main:refs/heads/beta" in text
    assert "--verify-refs" in text
    assert "--mode fast-forward" in text
    assert "git reset --hard main" not in text
    assert text.count("\n          ref: beta\n") == 1
    assert "needs.detect-promotion-scope.outputs.promotion_target_sha" in text
    assert "was not required but ran with result" in text
    assert "--decide-merge" in text
    assert "steps.merge_decision.outputs.merge_required == 'true'" in text
    assert "Preserve current main (no merge required)" in text
    assert text.count('git commit -m "$COMMIT_MESSAGE"') == 2
    assert "--validate-versions" in text
    assert "A promotion without addon changes must retain a stable X.Y.Z version" not in text


def test_merge_jobs_materialize_helper_that_supports_validate_versions():
    workflow = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "promote-beta-to-main.yml"
    text = workflow.read_text(encoding="utf-8")
    assert text.count("grep -q -- '--validate-versions'") == 3
    assert "grep -q -- '--decide-merge'" not in text
    assert 'materialize_scope_helper HEAD || materialize_scope_helper "$EXPECTED_TARGET"' not in text
    assert (
        text.count(
            'materialize_scope_helper "$EXPECTED_TARGET" || materialize_scope_helper HEAD'
        )
        == 2
    )


def test_pr_beta_validation_gates_release_checks_on_packaged_scope():
    workflow = (
        Path(__file__).resolve().parents[1]
        / ".github"
        / "workflows"
        / "pr-beta-validation.yml"
    )
    text = workflow.read_text(encoding="utf-8")
    assert "classify_promotion_scope.py" in text
    assert "release_required: ${{ steps.changes.outputs.release_required }}" in text
    assert text.count("needs.detect-addon-changes.outputs.release_required == 'true'") == 2
    assert "needs.detect-addon-changes.outputs.addon_changed == 'true'" not in text
    detect_start = text.index("detect-addon-changes:")
    detect_end = text.index("\n  lint:")
    detect_block = text[detect_start:detect_end]
    assert "classify_promotion_scope.py" in detect_block
    assert "--base" in detect_block
    assert "--head" in detect_block
    assert "git diff --name-only" not in detect_block


def test_post_merge_beta_classifies_push_range_and_keeps_housekeeping():
    workflow = (
        Path(__file__).resolve().parents[1] / ".github" / "workflows" / "post-merge-beta.yml"
    )
    text = workflow.read_text(encoding="utf-8")
    assert "classify_promotion_scope.py" in text
    assert "github.event.before" in text
    assert "needs.detect-release-scope.outputs.release_required == 'true'" in text
    assert "check_version_bump.py beta --base-commit" in text
    assert "check_duplicate_release.py" in text
    assert "verify_promotion_outcomes" in text
    assert "needs.publish-beta-release.result == 'skipped'" in text
    assert "cleanup-merged-branch:" in text
    publish_if = text[text.index("publish-beta-release:") : text.index("verify-release-outcome:")]
    assert "release_required == 'true'" in publish_if
    assert "!**/AGENTS.md" in text


def _repo_beta_equals_main(tmp_path):
    return init_repo(tmp_path)


def _repo_beta_behind_main(tmp_path, generated_on_main=True):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# B on beta\n"}, "docs: B")
    git(repo, "checkout", "main")
    git(repo, "merge", "--no-ff", "beta", "-m", "promote B")
    if generated_on_main:
        commit_files(
            repo,
            {
                "CHANGELOG.md": "# Changelog\n\n## generated on main\n",
                "README.md": "# README generated on main\n",
                "SpectrumFederation/SpectrumFederation.toc": (
                    "## Version: 1.4.1\n## Interface: 120100\n"
                ),
                "SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc": (
                    "## Version: 1.4.1\n## Interface: 120100\n"
                ),
                "SpectrumFederation_RCLootCouncilIntegration/SpectrumFederation_RCLootCouncilIntegration.toc": (
                    "## Version: 1.4.1\n## Interface: 120100\n"
                ),
            },
            "docs: generated main state",
        )
    git(repo, "checkout", "beta")
    return repo


def test_case_a_beta_equals_main_does_not_require_merge(tmp_path):
    repo = _repo_beta_equals_main(tmp_path)
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.has_incoming_changes is False
    assert scope.merge_required is False
    assert scope.release_required is False
    base, target = _captured_shas(repo)
    assert scope_mod.verify_promotion_refs(
        base, target, "main", "beta", cwd=repo, mode="merge"
    ) == []
    plan = scope_mod.plan_promotion_git_mutation("beta", "main", cwd=repo)
    assert plan["merge_required"] is False
    assert plan["create_merge_commit"] is False
    assert plan["overlay_captured_target_files"] == []
    ff_errors = scope_mod.verify_promotion_refs(
        base,
        target,
        "main",
        "beta",
        cwd=repo,
        mode="fast-forward",
        destination="main",
    )
    assert ff_errors == []


def test_case_b_beta_behind_main_does_not_require_merge(tmp_path):
    repo = _repo_beta_behind_main(tmp_path, generated_on_main=False)
    git(repo, "checkout", "main")
    main_sha = scope_mod.resolve_commit("HEAD", cwd=repo)
    git(repo, "checkout", "beta")
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.has_incoming_changes is False
    assert scope.merge_required is False
    plan = scope_mod.plan_promotion_git_mutation("beta", "main", cwd=repo)
    assert plan["merge_required"] is False
    assert plan["overlay_captured_target_files"] == []
    git(repo, "checkout", "main")
    assert scope_mod.resolve_commit("HEAD", cwd=repo) == main_sha
    assert scope_mod.git_is_ancestor("beta", "main", cwd=repo)


def test_case_b_fast_forward_allows_beta_to_catch_up(tmp_path):
    repo = _repo_beta_behind_main(tmp_path, generated_on_main=False)
    git(repo, "checkout", "beta")
    expected_base = scope_mod.resolve_commit("main", cwd=repo)
    expected_target = scope_mod.resolve_commit("beta", cwd=repo)
    errors = scope_mod.verify_promotion_refs(
        expected_base,
        expected_target,
        "main",
        "beta",
        cwd=repo,
        mode="merge",
    )
    assert errors == []
    ff_errors = scope_mod.verify_promotion_refs(
        expected_base,
        expected_target,
        "main",
        "beta",
        cwd=repo,
        mode="fast-forward",
        destination="main",
    )
    assert ff_errors == []
    assert scope_mod.git_is_ancestor("beta", "main", cwd=repo)


def test_case_c_noop_does_not_restore_older_beta_generated_files(tmp_path):
    repo = _repo_beta_behind_main(tmp_path, generated_on_main=True)
    git(repo, "checkout", "beta")
    beta_changelog = (repo / "CHANGELOG.md").read_text(encoding="utf-8")
    beta_readme = (repo / "README.md").read_text(encoding="utf-8")
    beta_toc = (repo / "SpectrumFederation" / "SpectrumFederation.toc").read_text(
        encoding="utf-8"
    )
    git(repo, "checkout", "main")
    main_changelog = (repo / "CHANGELOG.md").read_text(encoding="utf-8")
    main_readme = (repo / "README.md").read_text(encoding="utf-8")
    main_toc = (repo / "SpectrumFederation" / "SpectrumFederation.toc").read_text(
        encoding="utf-8"
    )
    assert main_changelog != beta_changelog
    assert main_readme != beta_readme
    assert main_toc != beta_toc
    plan = scope_mod.plan_promotion_git_mutation("beta", "main", cwd=repo)
    assert plan["merge_required"] is False
    assert plan["overlay_captured_target_files"] == []
    assert (repo / "CHANGELOG.md").read_text(encoding="utf-8") == main_changelog
    assert (repo / "README.md").read_text(encoding="utf-8") == main_readme
    assert (
        repo / "SpectrumFederation" / "SpectrumFederation.toc"
    ).read_text(encoding="utf-8") == main_toc


def test_case_d_genuine_incoming_beta_work_still_requires_merge(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming\n"}, "docs: incoming")
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.docs_changed is True
    assert scope.merge_required is True
    plan = scope_mod.plan_promotion_git_mutation("beta", "main", cwd=repo)
    assert plan["merge_required"] is True
    assert plan["create_merge_commit"] is True
    assert plan["overlay_captured_target_files"] == list(
        scope_mod.PROMOTION_MERGE_OVERLAY_PATHS
    )
    base, target = _captured_shas(repo)
    assert scope_mod.verify_promotion_refs(
        base, target, "main", "beta", cwd=repo, mode="merge"
    ) == []


def test_case_e_beta_advance_during_noop_refuses_fast_forward(tmp_path):
    repo = _repo_beta_behind_main(tmp_path, generated_on_main=True)
    expected_base = scope_mod.resolve_commit("main", cwd=repo)
    expected_target = scope_mod.resolve_commit("beta", cwd=repo)
    git(repo, "checkout", "beta")
    commit_files(repo, {"docs/index.md": "# newer beta\n"}, "docs: newer beta")
    newer = scope_mod.resolve_commit("beta", cwd=repo)
    errors = scope_mod.verify_promotion_refs(
        expected_base,
        expected_target,
        "main",
        "beta",
        cwd=repo,
        mode="fast-forward",
        destination="main",
    )
    assert any("Refusing to overwrite newer beta work" in error for error in errors)
    assert scope_mod.resolve_commit("beta", cwd=repo) == newer


def test_case_f_unexpected_main_move_still_fails_closed_on_noop_graph(tmp_path):
    repo = _repo_beta_behind_main(tmp_path, generated_on_main=True)
    expected_base = scope_mod.resolve_commit("main", cwd=repo)
    expected_target = scope_mod.resolve_commit("beta", cwd=repo)
    git(repo, "checkout", "main")
    commit_files(
        repo,
        {".github/workflows/promote-beta-to-main.yml": "name: unexpected main\n"},
        "ci: unexpected main change",
    )
    errors = scope_mod.verify_promotion_refs(
        expected_base,
        expected_target,
        "main",
        "beta",
        cwd=repo,
        mode="merge",
    )
    assert any("origin/main has moved" in error for error in errors)
    plan = scope_mod.plan_promotion_git_mutation(expected_target, "main", cwd=repo)
    assert plan["merge_required"] is False


def test_empty_beta_commit_requires_merge_even_without_incoming_files(tmp_path):
    repo = init_repo(tmp_path)
    git(repo, "commit", "--allow-empty", "-m", "empty beta commit")
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.has_incoming_changes is False
    assert scope.merge_required is True
    plan = scope_mod.plan_promotion_git_mutation("beta", "main", cwd=repo)
    assert plan["merge_required"] is True
    assert plan["overlay_captured_target_files"] == list(
        scope_mod.PROMOTION_MERGE_OVERLAY_PATHS
    )


def test_cli_decide_merge_reports_contained_target(tmp_path, monkeypatch, capsys):
    repo = _repo_beta_behind_main(tmp_path, generated_on_main=False)
    monkeypatch.chdir(repo)
    exit_code = scope_mod.main(
        [
            "--decide-merge",
            "--expected-target",
            scope_mod.resolve_commit("beta", cwd=repo),
            "--current-base",
            "main",
        ]
    )
    captured = capsys.readouterr()
    assert exit_code == 0
    assert "already contained in main" in captured.out


def parent_toc(version):
    return f"## Interface: 120100\n## Version: {version}\n"


def test_version_a_contained_prerelease_beta_accepts_stable_main(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {
            "SpectrumFederation/Core/Foo.lua": "print('feat')\n",
            "SpectrumFederation/SpectrumFederation.toc": parent_toc("1.4.2-beta.5"),
        },
        "feat: addon 1.4.2-beta.5",
    )
    git(repo, "checkout", "main")
    git(repo, "merge", "--no-ff", "beta", "-m", "promote addon")
    commit_files(
        repo,
        {"SpectrumFederation/SpectrumFederation.toc": parent_toc("1.4.2")},
        "chore: stable 1.4.2",
    )
    git(repo, "checkout", "beta")
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.release_required is False
    assert scope.merge_required is False
    assert scope_mod.read_toc_version_from_ref("beta", cwd=repo) == "1.4.2-beta.5"
    assert scope_mod.read_toc_version_from_ref("main", cwd=repo) == "1.4.2"
    errors = scope_mod.validate_promotion_toc_versions(
        scope.release_required,
        scope.merge_required,
        "beta",
        "main",
        cwd=repo,
    )
    assert errors == []
    plan = scope_mod.plan_promotion_git_mutation("beta", "main", cwd=repo)
    assert plan["create_merge_commit"] is False
    assert plan["overlay_captured_target_files"] == []
    ff_errors = scope_mod.verify_promotion_refs(
        scope_mod.resolve_commit("main", cwd=repo),
        scope_mod.resolve_commit("beta", cwd=repo),
        "main",
        "beta",
        cwd=repo,
        mode="fast-forward",
        destination="main",
    )
    assert ff_errors == []


def test_version_b_beta_equals_stable_main(tmp_path):
    repo = init_repo(tmp_path)
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.release_required is False
    assert scope.merge_required is False
    errors = scope_mod.validate_promotion_toc_versions(
        False, False, "beta", "main", cwd=repo
    )
    assert errors == []
    assert scope_mod.read_toc_version_from_ref("main", cwd=repo) == "1.4.1"


def test_version_c_non_addon_merge_with_stable_beta(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(repo, {"docs/index.md": "# incoming docs\n"}, "docs: incoming")
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.release_required is False
    assert scope.merge_required is True
    errors = scope_mod.validate_promotion_toc_versions(
        scope.release_required,
        scope.merge_required,
        "beta",
        "main",
        cwd=repo,
    )
    assert errors == []
    assert scope_mod.read_toc_version_from_ref("beta", cwd=repo) == "1.4.1"


def test_version_d_non_addon_merge_with_stale_beta_suffix_is_rejected(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {
            "SpectrumFederation/Core/Foo.lua": "print('feat')\n",
            "SpectrumFederation/SpectrumFederation.toc": parent_toc("1.4.2-beta.5"),
        },
        "feat: addon 1.4.2-beta.5",
    )
    git(repo, "checkout", "main")
    git(repo, "merge", "--no-ff", "beta", "-m", "promote addon")
    commit_files(
        repo,
        {"SpectrumFederation/SpectrumFederation.toc": parent_toc("1.4.2")},
        "chore: stable 1.4.2",
    )
    git(repo, "checkout", "beta")
    commit_files(repo, {"docs/index.md": "# later docs\n"}, "docs: after incomplete FF")
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.release_required is False
    assert scope.merge_required is True
    errors = scope_mod.validate_promotion_toc_versions(
        scope.release_required,
        scope.merge_required,
        "beta",
        "main",
        cwd=repo,
    )
    assert errors
    assert "stale release metadata" in errors[0]
    assert "1.4.2-beta.5" in errors[0]


def test_version_e_addon_release_requires_beta_suffix(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {
            "SpectrumFederation/Core/Foo.lua": "print('feat')\n",
            "SpectrumFederation/SpectrumFederation.toc": parent_toc("1.4.2-beta.5"),
        },
        "feat: addon 1.4.2-beta.5",
    )
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.release_required is True
    assert scope.merge_required is True
    errors = scope_mod.validate_promotion_toc_versions(
        scope.release_required,
        scope.merge_required,
        "beta",
        "main",
        cwd=repo,
    )
    assert errors == []


def test_version_e_addon_release_rejects_stable_beta_toc(tmp_path):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {"SpectrumFederation/Core/Foo.lua": "print('feat')\n"},
        "feat: addon without bumping to -beta",
    )
    scope = scope_mod.classify_git_range("main", "beta", cwd=repo)
    assert scope.release_required is True
    errors = scope_mod.validate_promotion_toc_versions(
        True, True, "beta", "main", cwd=repo
    )
    assert errors
    assert "X.Y.Z-beta.N" in errors[0]


def test_cli_validate_versions_accepts_noop_prerelease_beta(tmp_path, monkeypatch, capsys):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {
            "SpectrumFederation/Core/Foo.lua": "print('feat')\n",
            "SpectrumFederation/SpectrumFederation.toc": parent_toc("1.4.2-beta.5"),
        },
        "feat: addon 1.4.2-beta.5",
    )
    git(repo, "checkout", "main")
    git(repo, "merge", "--no-ff", "beta", "-m", "promote addon")
    commit_files(
        repo,
        {"SpectrumFederation/SpectrumFederation.toc": parent_toc("1.4.2")},
        "chore: stable 1.4.2",
    )
    monkeypatch.chdir(repo)
    exit_code = scope_mod.main(
        [
            "--validate-versions",
            "--expected-base",
            scope_mod.resolve_commit("main", cwd=repo),
            "--expected-target",
            scope_mod.resolve_commit("beta", cwd=repo),
        ]
    )
    captured = capsys.readouterr()
    assert exit_code == 0
    assert "release_required=false" in captured.out
    assert "merge_required=false" in captured.out
    assert "1.4.2" in captured.out


def test_cli_validate_versions_reports_missing_version_without_traceback(
    tmp_path, monkeypatch, capsys
):
    repo = init_repo(tmp_path)
    commit_files(
        repo,
        {"SpectrumFederation/SpectrumFederation.toc": "## Interface: 120100\n"},
        "chore: drop version line",
    )
    monkeypatch.chdir(repo)
    exit_code = scope_mod.main(
        [
            "--validate-versions",
            "--expected-base",
            scope_mod.resolve_commit("main", cwd=repo),
            "--expected-target",
            scope_mod.resolve_commit("beta", cwd=repo),
        ]
    )
    captured = capsys.readouterr()
    combined = captured.out + captured.err
    assert exit_code == 1
    assert "::error::" in captured.err
    assert "No '## Version:' line" in combined
    assert "Traceback" not in combined


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
