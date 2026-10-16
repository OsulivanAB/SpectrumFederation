from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from urllib import error

import pytest


MODULE_PATH = Path(__file__).resolve().parents[1] / ".github" / "scripts" / "wow_interface_sync.py"
SPEC = importlib.util.spec_from_file_location("wow_interface_sync", MODULE_PATH)
wow = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(wow)
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


class DummyResponse:
    def __init__(self, payload: bytes):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self.payload


def test_parse_patch_versions_payload_and_map_interface():
    payload = (FIXTURES_DIR / "blizzard_versions_sample.txt").read_text(encoding="utf-8")

    version = wow.parse_version_response(payload, region="us")
    interface = wow.version_to_interface(version)

    assert version == "12.0.1.63091"
    assert interface == 120001


def test_parse_https_fallback_versions():
    blizztrack_html = (FIXTURES_DIR / "blizztrack_versions_sample.html").read_text(encoding="utf-8")
    blizzmeta_html = (FIXTURES_DIR / "blizzmeta_versions_sample.html").read_text(encoding="utf-8")
    blizztrack_card_html = (FIXTURES_DIR / "blizztrack_live_card_sample.html").read_text(encoding="utf-8")

    assert wow.parse_live_version_from_text(blizztrack_html, source_name="BlizzTrack") == "12.0.1.63091"
    assert wow.parse_live_version_from_text(blizzmeta_html, source_name="BlizzMeta") == "12.0.1.63091"
    assert wow.parse_live_version_from_text(blizztrack_card_html, source_name="BlizzTrack") == "12.0.1.66263"


def test_http_get_retries_then_succeeds(monkeypatch):
    calls = {"count": 0}

    def fake_urlopen(_req, timeout):
        assert timeout == 30
        calls["count"] += 1
        if calls["count"] < 3:
            raise error.URLError("temporary issue")
        return DummyResponse(b"ok")

    monkeypatch.setattr(wow.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(wow.time, "sleep", lambda _: None)
    monkeypatch.setattr(wow.random, "uniform", lambda _a, _b: 0.0)

    payload = wow.http_get_with_retries("https://example.com", timeout=30, attempts=6, base_sleep=1, max_sleep=20)

    assert payload == "ok"
    assert calls["count"] == 3


def test_manual_override_used_after_network_failure(monkeypatch):
    monkeypatch.setenv("LIVE_INTERFACE_OVERRIDE", "120001")
    monkeypatch.setattr(
        wow,
        "_resolve_patch_server",
        lambda _region: (_ for _ in ()).throw(RuntimeError("patch down")),
    )
    monkeypatch.setattr(
        wow,
        "_resolve_https_fallback",
        lambda: (_ for _ in ()).throw(RuntimeError("https fallback down")),
    )

    version, interface, strategy = wow.resolve_live_interface("us")
    assert version is None
    assert interface == 120001
    assert strategy == "manual_override"


def test_invalid_manual_override_fails_loudly(monkeypatch):
    monkeypatch.setenv("LIVE_INTERFACE_OVERRIDE", "abc123")
    monkeypatch.setattr(
        wow,
        "_resolve_patch_server",
        lambda _region: (_ for _ in ()).throw(RuntimeError("patch down")),
    )
    monkeypatch.setattr(
        wow,
        "_resolve_https_fallback",
        lambda: (_ for _ in ()).throw(RuntimeError("fallback down")),
    )

    with pytest.raises(RuntimeError, match="LIVE_INTERFACE_OVERRIDE"):
        wow.resolve_live_interface("us")


def test_compute_updated_versions_keeps_ahead_beta_train():
    main_version = wow.parse_version("1.5.8")
    beta_version = wow.parse_version("1.6.0-beta.7")

    new_main, new_beta, beta_ahead = wow.compute_updated_versions(
        main_version,
        beta_version,
        main_update_needed=True,
        beta_update_needed=True,
    )

    assert new_main.raw == "1.5.9"
    assert new_beta.raw == "1.6.0-beta.8"
    assert beta_ahead is True


def test_compute_updated_versions_advances_beta_when_train_caught_by_main():
    main_version = wow.parse_version("1.5.8")
    beta_version = wow.parse_version("1.5.9-beta.7")

    new_main, new_beta, beta_ahead = wow.compute_updated_versions(
        main_version,
        beta_version,
        main_update_needed=True,
        beta_update_needed=True,
    )

    assert new_main.raw == "1.5.9"
    assert new_beta.raw == "1.5.10-beta.1"
    assert beta_ahead is True


def test_compute_updated_versions_advances_beta_when_branches_match():
    main_version = wow.parse_version("1.5.8")
    beta_version = wow.parse_version("1.5.8")

    new_main, new_beta, beta_ahead = wow.compute_updated_versions(
        main_version,
        beta_version,
        main_update_needed=True,
        beta_update_needed=True,
    )

    assert new_main.raw == "1.5.9"
    assert new_beta.raw == "1.5.10-beta.1"
    assert beta_ahead is True


def test_compute_updated_versions_skips_beta_when_interface_already_current():
    main_version = wow.parse_version("1.5.8")
    beta_version = wow.parse_version("1.6.0-beta.7")

    new_main, new_beta, beta_ahead = wow.compute_updated_versions(
        main_version,
        beta_version,
        main_update_needed=True,
        beta_update_needed=False,
    )

    assert new_main.raw == "1.5.9"
    assert new_beta.raw == "1.6.0-beta.7"
    assert beta_ahead is True


def test_parse_human_game_version_and_interface_conversion():
    parsed = wow.parse_human_game_version("12.1.5")
    assert parsed["normalized"] == "12.1.5"
    assert parsed["interface"] == 120105

    with_build = wow.parse_human_game_version("12.1.5.12345")
    assert with_build["normalized"] == "12.1.5"
    assert with_build["interface"] == 120105


def test_parse_human_game_version_rejects_invalid_input():
    with pytest.raises(RuntimeError, match="Invalid game version"):
        wow.parse_human_game_version("12.1")
    with pytest.raises(RuntimeError, match="Invalid game version"):
        wow.parse_human_game_version("not-a-version")
    with pytest.raises(RuntimeError, match="plausible"):
        wow.parse_human_game_version("99.0.0")


def test_verify_requested_matches_live():
    requested = wow.parse_human_game_version("12.1.5")
    assert wow.verify_requested_matches_live(requested, 120105, live_game_version="12.1.5.99999") == 120105
    with pytest.raises(RuntimeError, match="does not match live Retail"):
        wow.verify_requested_matches_live(requested, 120100, live_game_version="12.1.0.1")


def test_build_update_plan_noop_for_already_current_stable_on_both_branches(monkeypatch):
    """Post-promotion main=beta stable with matching Interface must not invent work."""
    monkeypatch.setattr(
        wow,
        "fetch_github_release",
        lambda version, *_args, **_kwargs: {"tag_name": f"v{version}", "prerelease": False}
        if version == "1.5.8"
        else None,
    )
    requested = wow.parse_human_game_version("12.1.0")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.0.66263",
        live_interface=120100,
        main_interface="120100",
        main_version_raw="1.5.8",
        beta_interface="120100",
        beta_version_raw="1.5.8",
        main_sha="abc",
        beta_sha="def",
        repo="owner/repo",
        token="token",
    )
    assert plan["main_update_needed"] is False
    assert plan["beta_update_needed"] is False
    assert plan["main_target_version"] == "1.5.8"
    assert plan["beta_target_version"] == "1.5.8"
    # Completed GitHub release + matching Interface: no bump and no republish.
    assert plan["main_action"] == "none"
    assert plan["beta_action"] == "none"
    assert plan["any_work"] is False


def test_build_update_plan_advances_beta_when_main_catches_train(monkeypatch):
    """Main Interface bump to 1.5.9 must roll beta off 1.5.9-beta.N even if Interface matches."""
    monkeypatch.setattr(wow, "fetch_github_release", lambda *_args, **_kwargs: None)
    requested = wow.parse_human_game_version("12.1.5")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.5.1",
        live_interface=120105,
        main_interface="120100",
        main_version_raw="1.5.8",
        beta_interface="120105",
        beta_version_raw="1.5.9-beta.7",
        main_sha="abc",
        beta_sha="def",
        repo="owner/repo",
        token="token",
        occupied_tags=set(),
    )
    assert plan["main_update_needed"] is True
    assert plan["beta_update_needed"] is True
    assert plan["main_target_version"] == "1.5.9"
    assert plan["beta_target_version"] == "1.5.10-beta.1"
    assert plan["main_action"] == "update"
    assert plan["beta_action"] == "update"


def test_build_update_plan_updates_both_branches(monkeypatch):
    monkeypatch.setattr(wow, "fetch_github_release", lambda *_args, **_kwargs: None)
    requested = wow.parse_human_game_version("12.1.5")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.5.1",
        live_interface=120105,
        main_interface="120100",
        main_version_raw="1.5.8",
        beta_interface="120100",
        beta_version_raw="1.6.0-beta.7",
        main_sha="abc",
        beta_sha="def",
        repo="owner/repo",
        token="token",
        occupied_tags=set(),
    )
    assert plan["main_update_needed"] is True
    assert plan["beta_update_needed"] is True
    assert plan["main_target_version"] == "1.5.9"
    assert plan["beta_target_version"] == "1.6.0-beta.8"
    assert plan["main_action"] == "update"
    assert plan["beta_action"] == "update"


def test_build_update_plan_rejects_unavailable_version(monkeypatch):
    monkeypatch.setattr(wow, "fetch_github_release", lambda *_args, **_kwargs: None)
    requested = wow.parse_human_game_version("12.2.0")
    with pytest.raises(RuntimeError, match="does not match live Retail"):
        wow.build_update_plan(
            requested=requested,
            live_game_version="12.1.5.1",
            live_interface=120105,
            main_interface="120100",
            main_version_raw="1.5.8",
            beta_interface="120100",
            beta_version_raw="1.6.0-beta.7",
            main_sha="abc",
            beta_sha="def",
        )


def test_plan_branch_action_recovers_incomplete_channel_matched_publish(monkeypatch):
    monkeypatch.setattr(wow, "fetch_github_release", lambda *_args, **_kwargs: None)
    assert (
        wow.plan_branch_action(
            channel="main",
            interface_matches=True,
            version_raw="1.5.9",
            repo="owner/repo",
            token="token",
        )
        == "publish"
    )
    assert (
        wow.plan_branch_action(
            channel="beta",
            interface_matches=True,
            version_raw="1.6.0-beta.8",
            repo="owner/repo",
            token="token",
        )
        == "publish"
    )


def test_plan_branch_action_skips_already_completed_channel_release(monkeypatch):
    monkeypatch.setattr(
        wow,
        "fetch_github_release",
        lambda version, *_args, **_kwargs: {
            "tag_name": f"v{version}",
            "prerelease": "-" in version,
        },
    )
    assert (
        wow.plan_branch_action(
            channel="main",
            interface_matches=True,
            version_raw="1.5.8",
            repo="owner/repo",
            token="token",
        )
        == "none"
    )
    assert (
        wow.plan_branch_action(
            channel="beta",
            interface_matches=True,
            version_raw="1.6.0-beta.8",
            repo="owner/repo",
            token="token",
        )
        == "none"
    )


def test_plan_branch_action_retry_publication_republishes_existing_release(monkeypatch):
    monkeypatch.setattr(
        wow,
        "fetch_github_release",
        lambda version, *_args, **_kwargs: {
            "tag_name": f"v{version}",
            "prerelease": "-" in version,
        },
    )
    assert (
        wow.plan_branch_action(
            channel="main",
            interface_matches=True,
            version_raw="1.5.8",
            repo="owner/repo",
            token="token",
            retry_publication=True,
        )
        == "publish"
    )
    assert (
        wow.plan_branch_action(
            channel="beta",
            interface_matches=True,
            version_raw="1.6.0-beta.8",
            repo="owner/repo",
            token="token",
            retry_publication=True,
        )
        == "publish"
    )
    # Stable TOC on beta remains forbidden even during deliberate retry.
    assert (
        wow.plan_branch_action(
            channel="beta",
            interface_matches=True,
            version_raw="1.5.8",
            repo="owner/repo",
            token="token",
            retry_publication=True,
        )
        == "none"
    )


def test_build_update_plan_retry_publication_no_toc_bump(monkeypatch):
    monkeypatch.setattr(
        wow,
        "fetch_github_release",
        lambda version, *_args, **_kwargs: {
            "tag_name": f"v{version}",
            "prerelease": "-" in version,
        },
    )
    requested = wow.parse_human_game_version("12.1.0")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.0.66263",
        live_interface=120100,
        main_interface="120100",
        main_version_raw="1.5.8",
        beta_interface="120100",
        beta_version_raw="1.5.9-beta.7",
        main_sha="abc",
        beta_sha="def",
        repo="owner/repo",
        token="token",
        retry_publication=True,
    )
    assert plan["main_update_needed"] is False
    assert plan["beta_update_needed"] is False
    assert plan["main_target_version"] == "1.5.8"
    assert plan["beta_target_version"] == "1.5.9-beta.7"
    assert plan["main_action"] == "publish"
    assert plan["beta_action"] == "publish"
    assert plan["any_work"] is True


def test_plan_branch_action_refuses_stable_beta_and_wrong_channel_release(monkeypatch):
    assert (
        wow.plan_branch_action(
            channel="beta",
            interface_matches=True,
            version_raw="1.5.8",
            repo="owner/repo",
            token="token",
        )
        == "none"
    )

    monkeypatch.setattr(
        wow,
        "fetch_github_release",
        lambda *_args, **_kwargs: {"tag_name": "v1.5.9", "prerelease": True},
    )
    with pytest.raises(RuntimeError, match="prerelease"):
        wow.plan_branch_action(
            channel="main",
            interface_matches=True,
            version_raw="1.5.9",
            repo="owner/repo",
            token="token",
        )


def test_build_update_plan_avoids_tag_collisions_after_rollback(monkeypatch):
    monkeypatch.setattr(wow, "fetch_github_release", lambda *_args, **_kwargs: None)
    requested = wow.parse_human_game_version("12.1.5")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.5.1",
        live_interface=120105,
        main_interface="120100",
        main_version_raw="1.5.8",
        beta_interface="120100",
        beta_version_raw="1.6.0-beta.7",
        main_sha="abc",
        beta_sha="def",
        repo="owner/repo",
        token="token",
        occupied_tags={"v1.5.9", "v1.6.0-beta.8"},
    )
    assert plan["main_target_version"] == "1.5.10"
    assert plan["beta_target_version"] == "1.6.0-beta.9"


def test_materialize_workflow_helpers_from_newer_commit(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)

    scripts = repo / ".github" / "scripts"
    scripts.mkdir(parents=True)
    for name in (
        "wow_interface_sync.py",
        "update_changelog.py",
        "publish_release.py",
        "validate_packaging.py",
        "blizzard_api.py",
    ):
        (scripts / name).write_text(f"# old {name}\n", encoding="utf-8")
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "old helpers"], cwd=repo, check=True)
    old_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    for name in (
        "wow_interface_sync.py",
        "update_changelog.py",
        "publish_release.py",
        "validate_packaging.py",
        "blizzard_api.py",
    ):
        (scripts / name).write_text(f"# new {name}\nAPPLY_OK=1\n", encoding="utf-8")
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "new helpers"], cwd=repo, check=True)
    new_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    # Simulate operating on the older beta tip while helpers come from main/workflow.
    subprocess.run(["git", "checkout", "-q", old_sha], cwd=repo, check=True)
    destination = tmp_path / "helpers"
    paths = wow.materialize_workflow_helpers(repo, new_sha, destination)
    assert len(paths) >= 5
    assert "APPLY_OK=1" in (destination / "wow_interface_sync.py").read_text(encoding="utf-8")
    assert "# old wow_interface_sync.py" in (repo / ".github/scripts/wow_interface_sync.py").read_text(
        encoding="utf-8"
    )


def test_assert_no_conflicting_workflow_runs_detects_post_merge(monkeypatch):
    class DummyResponse:
        def __init__(self, payload):
            self.payload = json.dumps(payload).encode("utf-8")

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return self.payload

    calls = {"n": 0}

    def fake_urlopen(req, timeout=30):
        calls["n"] += 1
        url = req.full_url
        if "status=in_progress" in url:
            return DummyResponse(
                {
                    "workflow_runs": [
                        {
                            "id": 99,
                            "name": "Post-Merge Beta",
                            "run_number": 12,
                            "html_url": "https://example.test/runs/99",
                        }
                    ]
                }
            )
        return DummyResponse({"workflow_runs": []})

    monkeypatch.setattr(wow.request, "urlopen", fake_urlopen)
    with pytest.raises(RuntimeError, match="Post-Merge Beta"):
        wow.assert_no_conflicting_workflow_runs("owner/repo", "token", current_run_id="1")


def test_ensure_beta_release_concurrency_rewrites_old_group(tmp_path):
    path = tmp_path / "post-merge-beta.yml"
    path.write_text(
        "concurrency:\n  group: beta-release\n  cancel-in-progress: false\n",
        encoding="utf-8",
    )
    assert wow.ensure_release_channels_concurrency(path) is True
    text = path.read_text(encoding="utf-8")
    assert "group: release-channels" in text
    assert "queue: max" in text
    assert wow.ensure_release_channels_concurrency(path) is False


def test_materialize_helpers_bootstrap_works_without_sibling_imports(tmp_path):
    """Isolated bootstrap of wow_interface_sync.py must still materialize deps."""
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)

    scripts = repo / ".github" / "scripts"
    scripts.mkdir(parents=True)
    for name in (
        "wow_interface_sync.py",
        "update_changelog.py",
        "publish_release.py",
        "validate_packaging.py",
        "blizzard_api.py",
    ):
        (scripts / name).write_text(f"# pin {name}\nPINNED=1\n", encoding="utf-8")
    # Overwrite sync with the real module so import/lazy-load behavior is exercised.
    real_sync = (
        Path(__file__).resolve().parents[1] / ".github" / "scripts" / "wow_interface_sync.py"
    ).read_text(encoding="utf-8")
    (scripts / "wow_interface_sync.py").write_text(real_sync, encoding="utf-8")
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "pinned helpers"], cwd=repo, check=True)
    workflow_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    # Older beta tip: strip helpers from the working tree.
    for name in (
        "wow_interface_sync.py",
        "update_changelog.py",
        "publish_release.py",
        "validate_packaging.py",
        "blizzard_api.py",
    ):
        (scripts / name).write_text("# ancient stub\n", encoding="utf-8")
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "ancient beta tip"], cwd=repo, check=True)

    bootstrap = tmp_path / "bootstrap_wow_interface_sync.py"
    content = subprocess.run(
        ["git", "-C", str(repo), "show", f"{workflow_sha}:.github/scripts/wow_interface_sync.py"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    bootstrap.write_text(content, encoding="utf-8")
    destination = tmp_path / "helpers"
    result = subprocess.run(
        [
            sys.executable,
            str(bootstrap),
            "--materialize-helpers",
            str(destination),
            "--workflow-sha",
            workflow_sha,
            "--repo-path",
            str(repo),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    assert (destination / "validate_packaging.py").exists()
    assert "PINNED=1" in (destination / "validate_packaging.py").read_text(encoding="utf-8")
    assert (destination / "wow_interface_sync.py").exists()


def test_workflow_pins_helpers_and_requires_admin_pat():
    workflow = (
        Path(__file__).resolve().parents[1]
        / ".github"
        / "workflows"
        / "update-wow-game-version.yml"
    ).read_text(encoding="utf-8")
    assert "HELPERS_DIR" in workflow
    assert "secrets.PAT_TOKEN" in workflow
    assert "--assert-no-conflicts" in workflow
    assert "Refuse stable-version beta publish" in workflow
    assert "bootstrap_wow_interface_sync.py" not in workflow
    assert 'git show "$WORKFLOW_SHA:.github/scripts/$name"' in workflow
    assert "queue: max" in workflow
    assert "retry_publication:" in workflow
    assert "--retry-publication" in workflow
    assert "sync_needed" in workflow
    assert "beta_branch_mutation" in workflow
    assert "--integrate-main-into-beta" in workflow
    assert "needs: [preflight, update-main]" in workflow
    assert "chore: sync main game-version update into beta" in workflow
    post_merge = (
        Path(__file__).resolve().parents[1]
        / ".github"
        / "workflows"
        / "post-merge-beta.yml"
    ).read_text(encoding="utf-8")
    assert "chore: bump Interface to" in post_merge
    assert "chore: sync main game-version update into beta" in post_merge
    assert "group: release-channels" in post_merge
    assert "queue: max" in post_merge
    for name in ("promote-beta-to-main.yml", "rollback-release.yml"):
        text = (
            Path(__file__).resolve().parents[1] / ".github" / "workflows" / name
        ).read_text(encoding="utf-8")
        assert "group: release-channels" in text
        assert "queue: max" in text


def test_update_packaged_tocs_keeps_children_in_lockstep(tmp_path):
    root = tmp_path
    parent = root / "SpectrumFederation"
    parent.mkdir()
    parent_toc = parent / "SpectrumFederation.toc"
    parent_toc.write_text("## Interface: 120100\n## Version: 1.5.8\n", encoding="utf-8")

    for child in (
        "SpectrumFederation_CursedSurgeTracker",
        "SpectrumFederation_RCLootCouncilIntegration",
    ):
        child_dir = root / child
        child_dir.mkdir()
        (child_dir / f"{child}.toc").write_text(
            "## Interface: 120100\n## Version: 1.5.8\n## Title: child\n",
            encoding="utf-8",
        )

    assert wow.update_packaged_tocs(parent_toc, "120105", "1.5.9") is True
    for toc in (
        parent_toc,
        root / "SpectrumFederation_CursedSurgeTracker" / "SpectrumFederation_CursedSurgeTracker.toc",
        root / "SpectrumFederation_RCLootCouncilIntegration" / "SpectrumFederation_RCLootCouncilIntegration.toc",
    ):
        interface, version = wow.read_toc_fields(toc)
        assert interface == "120105"
        assert version == "1.5.9"


def test_verify_git_sha_detects_drift(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()

    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
    (repo / "file.txt").write_text("one\n", encoding="utf-8")
    subprocess.run(["git", "add", "file.txt"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "one"], cwd=repo, check=True)
    sha1 = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    (repo / "file.txt").write_text("two\n", encoding="utf-8")
    subprocess.run(["git", "add", "file.txt"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "two"], cwd=repo, check=True)

    with pytest.raises(RuntimeError, match="advanced unexpectedly"):
        wow.verify_git_sha(repo, "HEAD", sha1, label="main")
    assert wow.verify_git_sha(repo, "HEAD", wow.resolve_git_sha(repo, "HEAD"), label="main")


def test_write_output_appends_expected_keys(tmp_path, monkeypatch):
    output_file = tmp_path / "outputs.txt"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output_file))

    wow.write_output("main_updated", "true")
    wow.write_output("beta_updated", "false")
    wow.write_output("interface", "120001")

    content = output_file.read_text(encoding="utf-8")
    assert "main_updated=true" in content
    assert "beta_updated=false" in content
    assert "interface=120001" in content


def test_no_network_requires_override(monkeypatch):
    monkeypatch.delenv("LIVE_INTERFACE_OVERRIDE", raising=False)
    with pytest.raises(RuntimeError, match="--no-network"):
        wow.resolve_live_interface("us", allow_network=False)


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _write_channel_tree(
    repo: Path,
    *,
    interface: str,
    version: str,
    track: str,
    changelog_versions: list[tuple[str, str]],
    extra_files: dict[str, str] | None = None,
) -> None:
    """Write the five generated metadata files plus optional beta-only content."""
    for rel in (
        "SpectrumFederation/SpectrumFederation.toc",
        "SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc",
        "SpectrumFederation_RCLootCouncilIntegration/SpectrumFederation_RCLootCouncilIntegration.toc",
    ):
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"## Interface: {interface}\n## Title: Spectrum\n## Version: {version}\n",
            encoding="utf-8",
        )

    version_badge = version.replace("-", "--")
    track_value = "Beta" if track == "beta" else "Retail"
    interface_display = f"{interface[0:2].lstrip('0') or '0'}.{int(interface[2:4])}.{int(interface[4:6])}"
    (repo / "README.md").write_text(
        "\n".join(
            [
                f"![Interface](https://img.shields.io/badge/Interface-{interface_display}-00aaff)",
                f"![Track](https://img.shields.io/badge/Track-{track_value}-ff8800)",
                f"![Addon Version](https://img.shields.io/badge/Version-{version_badge}-brightgreen)",
                "",
                "# SpectrumFederation",
                "",
                "Unrelated readme body that must survive sync.",
                "",
            ]
        ),
        encoding="utf-8",
    )

    sections = ["# Changelog", "", "All notable changes to SpectrumFederation will be documented in this file.", ""]
    for section_version, body in changelog_versions:
        sections.extend([f"## [{section_version}] - 2026-10-13", "", body, ""])
    (repo / "CHANGELOG.md").write_text("\n".join(sections), encoding="utf-8")

    for rel, content in (extra_files or {}).items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def _init_divergent_game_version_repo(tmp_path: Path):
    """Reproduce the 1.5.10 / 1.5.11-beta.1 parallel-bump divergence from run 38411587189."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")

    _write_channel_tree(
        repo,
        interface="120100",
        version="1.5.9",
        track="main",
        changelog_versions=[
            (
                "1.5.9",
                "### Changed\n- Prior stable release note\n",
            )
        ],
        extra_files={"SpectrumFederation/Core.lua": "print('shared')\n"},
    )
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "shared base before game-version bumps")
    base_sha = _git(repo, "rev-parse", "HEAD")

    _git(repo, "checkout", "-b", "beta")
    _write_channel_tree(
        repo,
        interface="120100",
        version="1.5.9",
        track="beta",
        changelog_versions=[
            (
                "1.5.9",
                "### Changed\n- Prior stable release note\n",
            )
        ],
        extra_files={
            "SpectrumFederation/Core.lua": "print('shared')\n",
            "SpectrumFederation/.sf-beta-only-probe": "beta-only-feature\n",
            "SpectrumFederation/BetaOnly.lua": "return 'keep-me'\n",
        },
    )
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "beta-only development ahead of shared base")
    beta_base_sha = _git(repo, "rev-parse", "HEAD")

    # Independent main bump (stable 1.5.10 / Interface 120105).
    _git(repo, "checkout", "main")
    _write_channel_tree(
        repo,
        interface="120105",
        version="1.5.10",
        track="main",
        changelog_versions=[
            (
                "1.5.10",
                "### Changed\n- Updated Retail game compatibility to Interface 120105 (12.1.5).\n",
            ),
            (
                "1.5.9",
                "### Changed\n- Prior stable release note\n",
            ),
        ],
        extra_files={"SpectrumFederation/Core.lua": "print('shared')\n"},
    )
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "chore: bump Interface to 120105 and version to 1.5.10 [skip ci]")
    main_sha = _git(repo, "rev-parse", "HEAD")

    # Independent beta bump (1.5.11-beta.1 / Interface 120105) from pre-main tip.
    _git(repo, "checkout", "beta")
    _write_channel_tree(
        repo,
        interface="120105",
        version="1.5.11-beta.1",
        track="beta",
        changelog_versions=[
            (
                "1.5.11-beta.1",
                "### Changed\n- Updated Retail game compatibility to Interface 120105 (12.1.5).\n",
            ),
            (
                "1.5.9",
                "### Changed\n- Prior stable release note\n",
            ),
        ],
        extra_files={
            "SpectrumFederation/Core.lua": "print('shared')\n",
            "SpectrumFederation/.sf-beta-only-probe": "beta-only-feature\n",
            "SpectrumFederation/BetaOnly.lua": "return 'keep-me'\n",
        },
    )
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "chore: bump Interface to 120105 and version to 1.5.11-beta.1 [skip ci]")
    beta_sha = _git(repo, "rev-parse", "HEAD")

    assert not wow.git_is_ancestor(repo, main_sha, beta_sha)
    return {
        "repo": repo,
        "base_sha": base_sha,
        "beta_base_sha": beta_base_sha,
        "main_sha": main_sha,
        "beta_sha": beta_sha,
    }


def test_reconcile_changelog_preserves_both_channel_sections():
    ours = "\n".join(
        [
            "# Changelog",
            "",
            "## [1.5.11-beta.1] - 2026-10-13",
            "",
            "### Changed",
            "- Updated Retail game compatibility to Interface 120105 (12.1.5).",
            "",
            "## [1.5.9] - 2026-10-13",
            "",
            "### Changed",
            "- Prior stable release note",
            "",
        ]
    )
    theirs = "\n".join(
        [
            "# Changelog",
            "",
            "## [1.5.10] - 2026-10-13",
            "",
            "### Changed",
            "- Updated Retail game compatibility to Interface 120105 (12.1.5).",
            "",
            "## [1.5.9] - 2026-10-13",
            "",
            "### Changed",
            "- Prior stable release note",
            "",
        ]
    )
    merged = wow.reconcile_changelog_texts(ours, theirs)
    assert "## [1.5.11-beta.1]" in merged
    assert "## [1.5.10]" in merged
    assert merged.count("## [1.5.9]") == 1
    beta_pos = merged.index("## [1.5.11-beta.1]")
    stable_pos = merged.index("## [1.5.10]")
    prior_pos = merged.index("## [1.5.9]")
    assert beta_pos < stable_pos < prior_pos


def test_reconcile_changelog_rejects_incompatible_same_version():
    ours = "# Changelog\n\n## [1.5.10] - 2026-10-13\n\n### Changed\n- Alpha\n"
    theirs = "# Changelog\n\n## [1.5.10] - 2026-10-13\n\n### Changed\n- Beta\n"
    with pytest.raises(RuntimeError, match="Incompatible CHANGELOG.md"):
        wow.reconcile_changelog_texts(ours, theirs)


def test_assert_changelog_delta_rejects_preface_and_existing_section_edits():
    base = "\n".join(
        [
            "# Changelog",
            "",
            "All notable changes to SpectrumFederation will be documented in this file.",
            "",
            "## [1.5.9] - 2026-10-13",
            "",
            "### Changed",
            "- Prior stable release note",
            "",
            "Historical context paragraph that must stay unchanged.",
            "",
        ]
    )
    legitimate_head = "\n".join(
        [
            "# Changelog",
            "",
            "All notable changes to SpectrumFederation will be documented in this file.",
            "",
            "## [1.5.10] - 2026-10-13",
            "",
            "### Changed",
            "- Updated Retail game compatibility to Interface 120105 (12.1.5).",
            "",
            "## [1.5.9] - 2026-10-13",
            "",
            "### Changed",
            "- Prior stable release note",
            "",
            "Historical context paragraph that must stay unchanged.",
            "",
        ]
    )
    wow.assert_changelog_delta_is_generated_only(base, legitimate_head, label="Test")

    preface_edited = legitimate_head.replace(
        "All notable changes to SpectrumFederation will be documented in this file.",
        "Main-only marketing preface that must not sync automatically.",
    )
    with pytest.raises(RuntimeError, match="unversioned preface"):
        wow.assert_changelog_delta_is_generated_only(base, preface_edited, label="Test")

    # Same bullets, different non-bullet prose in a pre-existing section.
    prose_edited = legitimate_head.replace(
        "Historical context paragraph that must stay unchanged.",
        "Rewritten historical blurb that must not sync automatically.",
    )
    with pytest.raises(RuntimeError, match="modified existing section 1\\.5\\.9"):
        wow.assert_changelog_delta_is_generated_only(base, prose_edited, label="Test")

    # New section with compatibility bullet plus unrelated prose.
    polluted_new = "\n".join(
        [
            "# Changelog",
            "",
            "All notable changes to SpectrumFederation will be documented in this file.",
            "",
            "## [1.5.10] - 2026-10-13",
            "",
            "Unrelated paragraph before the generated note.",
            "",
            "### Changed",
            "- Updated Retail game compatibility to Interface 120105 (12.1.5).",
            "",
            "## [1.5.9] - 2026-10-13",
            "",
            "### Changed",
            "- Prior stable release note",
            "",
            "Historical context paragraph that must stay unchanged.",
            "",
        ]
    )
    with pytest.raises(RuntimeError, match="non-generated content under 1\\.5\\.10"):
        wow.assert_changelog_delta_is_generated_only(base, polluted_new, label="Test")


def test_original_parallel_bump_sync_preserves_ancestry_and_metadata(tmp_path):
    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]
    _git(repo, "checkout", "beta")

    result = wow.integrate_main_into_beta(
        repo,
        main_sha=state["main_sha"],
        beta_interface="120105",
        beta_version="1.5.11-beta.1",
        game_version="12.1.5",
        beta_update_needed=False,
        commit=True,
    )
    assert result["synced"] is True
    assert wow.git_is_ancestor(repo, state["main_sha"], result["commit_sha"])

    interface, version = wow.read_toc_fields_from_git(
        repo, "HEAD", "SpectrumFederation/SpectrumFederation.toc"
    )
    assert interface == "120105"
    assert version == "1.5.11-beta.1"
    for child in (
        "SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc",
        "SpectrumFederation_RCLootCouncilIntegration/SpectrumFederation_RCLootCouncilIntegration.toc",
    ):
        child_interface, child_version = wow.read_toc_fields_from_git(repo, "HEAD", child)
        assert child_interface == "120105"
        assert child_version == "1.5.11-beta.1"

    readme = wow.read_git_blob(repo, "HEAD", "README.md")
    assert "Track-Beta" in readme
    assert "Version-1.5.11--beta.1" in readme
    assert "Unrelated readme body that must survive sync." in readme

    changelog = wow.read_git_blob(repo, "HEAD", "CHANGELOG.md")
    assert "## [1.5.11-beta.1]" in changelog
    assert "## [1.5.10]" in changelog
    assert wow.read_git_blob(repo, "HEAD", "SpectrumFederation/BetaOnly.lua") == "return 'keep-me'\n"


def test_unexpected_non_metadata_conflict_fails_safely(tmp_path):
    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]

    _git(repo, "checkout", "main")
    (repo / "SpectrumFederation" / "Core.lua").write_text("print('main-only')\n", encoding="utf-8")
    _git(repo, "add", "SpectrumFederation/Core.lua")
    _git(repo, "commit", "-m", "unrelated main code change")
    bad_main = _git(repo, "rev-parse", "HEAD")

    _git(repo, "checkout", "beta")
    with pytest.raises(RuntimeError, match="outside generated game-version metadata|files outside generated"):
        wow.integrate_main_into_beta(
            repo,
            main_sha=bad_main,
            beta_interface="120105",
            beta_version="1.5.11-beta.1",
            game_version="12.1.5",
            beta_update_needed=False,
            commit=True,
        )


def test_identify_sync_distinguishes_noop_from_history_sync(tmp_path):
    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]

    needed, sync_sha, reason = wow.identify_sync_main_sha(
        repo,
        main_sha=state["main_sha"],
        beta_sha=state["beta_sha"],
        main_update_needed=False,
    )
    assert needed is True
    assert sync_sha == state["main_sha"]
    assert "missing from beta ancestry" in reason

    _git(repo, "checkout", "beta")
    wow.integrate_main_into_beta(
        repo,
        main_sha=state["main_sha"],
        beta_interface="120105",
        beta_version="1.5.11-beta.1",
        game_version="12.1.5",
        beta_update_needed=False,
        commit=True,
    )
    beta_after = _git(repo, "rev-parse", "HEAD")
    needed, sync_sha, reason = wow.identify_sync_main_sha(
        repo,
        main_sha=state["main_sha"],
        beta_sha=beta_after,
        main_update_needed=False,
    )
    assert needed is False
    assert sync_sha == ""
    assert "already an ancestor" in reason


def test_history_only_sync_is_non_release_for_post_merge(tmp_path):
    scope_path = Path(__file__).resolve().parents[1] / ".github" / "scripts" / "classify_promotion_scope.py"
    scope_spec = importlib.util.spec_from_file_location("classify_promotion_scope_sync", scope_path)
    scope = importlib.util.module_from_spec(scope_spec)
    assert scope_spec and scope_spec.loader
    sys.modules[scope_spec.name] = scope
    scope_spec.loader.exec_module(scope)

    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]
    _git(repo, "checkout", "beta")
    before = state["beta_sha"]
    wow.integrate_main_into_beta(
        repo,
        main_sha=state["main_sha"],
        beta_interface="120105",
        beta_version="1.5.11-beta.1",
        game_version="12.1.5",
        beta_update_needed=False,
        commit=True,
    )
    after = _git(repo, "rev-parse", "HEAD")
    classified = scope.classify_git_range(before, after, cwd=repo)
    assert classified.release_required is False
    assert classified.changelog_changed is True


def test_simulate_integration_for_parallel_update_without_remote_mutation(tmp_path, monkeypatch):
    repo = tmp_path / "fresh"
    repo.mkdir()
    _git(repo, "init", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    _write_channel_tree(
        repo,
        interface="120100",
        version="1.5.9",
        track="main",
        changelog_versions=[("1.5.9", "### Changed\n- Prior\n")],
        extra_files={"SpectrumFederation/Core.lua": "print('shared')\n"},
    )
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "base")
    main_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "checkout", "-b", "beta")
    (repo / "SpectrumFederation" / ".sf-beta-only-probe").write_text("probe\n", encoding="utf-8")
    (repo / "SpectrumFederation" / "BetaOnly.lua").write_text("return 1\n", encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "beta-only")
    beta_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "checkout", "main")

    monkeypatch.setattr(wow, "fetch_github_release", lambda *_a, **_k: None)
    requested = wow.parse_human_game_version("12.1.5")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.5.1",
        live_interface=120105,
        main_interface="120100",
        main_version_raw="1.5.9",
        beta_interface="120100",
        beta_version_raw="1.5.9",
        main_sha=main_sha,
        beta_sha=beta_sha,
        repo="owner/repo",
        token="token",
        repo_path=repo,
    )
    assert plan["sync_needed"] is True
    assert plan["main_target_version"] == "1.5.10"
    assert plan["beta_target_version"] == "1.5.11-beta.1"

    simulation = wow.simulate_channel_integration(
        repo,
        plan,
        work_dir=tmp_path / "sim",
        game_version="12.1.5",
    )
    assert simulation["ok"] is True
    assert simulation["main_version"] == "1.5.10"
    assert simulation["beta_version"] == "1.5.11-beta.1"
    # Original refs remain untouched.
    assert _git(repo, "rev-parse", "main") == main_sha
    assert _git(repo, "rev-parse", "beta") == beta_sha


def test_build_update_plan_retry_publication_blocked_when_sync_pending(tmp_path, monkeypatch):
    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]
    monkeypatch.setattr(
        wow,
        "fetch_github_release",
        lambda version, *_a, **_k: {"prerelease": "beta" in version},
    )
    requested = wow.parse_human_game_version("12.1.5")
    with pytest.raises(RuntimeError, match="retry_publication cannot mutate"):
        wow.build_update_plan(
            requested=requested,
            live_game_version="12.1.5.1",
            live_interface=120105,
            main_interface="120105",
            main_version_raw="1.5.10",
            beta_interface="120105",
            beta_version_raw="1.5.11-beta.1",
            main_sha=state["main_sha"],
            beta_sha=state["beta_sha"],
            repo="owner/repo",
            token="token",
            retry_publication=True,
            repo_path=repo,
        )


def test_promotion_scope_after_sync_still_sees_beta_only_addon_work(tmp_path):
    scope_path = Path(__file__).resolve().parents[1] / ".github" / "scripts" / "classify_promotion_scope.py"
    scope_spec = importlib.util.spec_from_file_location("classify_promotion_scope_promo", scope_path)
    scope = importlib.util.module_from_spec(scope_spec)
    assert scope_spec and scope_spec.loader
    sys.modules[scope_spec.name] = scope
    scope_spec.loader.exec_module(scope)

    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]
    _git(repo, "checkout", "beta")
    wow.integrate_main_into_beta(
        repo,
        main_sha=state["main_sha"],
        beta_interface="120105",
        beta_version="1.5.11-beta.1",
        game_version="12.1.5",
        beta_update_needed=False,
        commit=True,
    )
    # Promote-style classification from main tip to synchronized beta tip.
    classified = scope.classify_git_range(state["main_sha"], "HEAD", cwd=repo)
    assert classified.release_required is True
    assert any(path.endswith("BetaOnly.lua") for path in classified.addon_files)
    assert wow.git_is_ancestor(repo, state["main_sha"], _git(repo, "rev-parse", "HEAD"))


def test_identify_sync_rejects_unrelated_main_divergence(tmp_path):
    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]
    _git(repo, "checkout", "main")
    (repo / "docs").mkdir(exist_ok=True)
    (repo / "docs" / "extra.md").write_text("docs only\n", encoding="utf-8")
    _git(repo, "add", "docs/extra.md")
    _git(repo, "commit", "-m", "docs on main after bump")
    drifted_main = _git(repo, "rev-parse", "HEAD")

    with pytest.raises(RuntimeError, match="outside generated game-version metadata|files outside generated"):
        wow.identify_sync_main_sha(
            repo,
            main_sha=drifted_main,
            beta_sha=state["beta_sha"],
            main_update_needed=False,
        )


def test_unrelated_readme_body_edit_on_main_fails_preflight_sync(tmp_path, monkeypatch):
    """Content-level guard: allowlisted README path with unrelated body edit is rejected."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    _write_channel_tree(
        repo,
        interface="120100",
        version="1.5.9",
        track="main",
        changelog_versions=[("1.5.9", "### Changed\n- Prior\n")],
        extra_files={"SpectrumFederation/Core.lua": "print('shared')\n"},
    )
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "base")
    _git(repo, "checkout", "-b", "beta")
    (repo / "SpectrumFederation" / "BetaOnly.lua").write_text("return 1\n", encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "beta-only")
    beta_sha = _git(repo, "rev-parse", "HEAD")

    _git(repo, "checkout", "main")
    # Unrelated body edit on the allowlisted README path before the Interface bump.
    readme = (repo / "README.md").read_text(encoding="utf-8")
    (repo / "README.md").write_text(
        readme.replace(
            "Unrelated readme body that must survive sync.",
            "Main-only marketing blurb that must not sync automatically.",
        ),
        encoding="utf-8",
    )
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-m", "docs: unrelated main README body edit")
    main_sha = _git(repo, "rev-parse", "HEAD")

    monkeypatch.setattr(wow, "fetch_github_release", lambda *_a, **_k: None)
    requested = wow.parse_human_game_version("12.1.5")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.5.1",
        live_interface=120105,
        main_interface="120100",
        main_version_raw="1.5.9",
        beta_interface="120100",
        beta_version_raw="1.5.9",
        main_sha=main_sha,
        beta_sha=beta_sha,
        repo="owner/repo",
        token="token",
        repo_path=repo,
    )
    assert plan["main_update_needed"] is True
    assert plan["sync_needed"] is True
    with pytest.raises(RuntimeError, match="outside generated badges"):
        wow.simulate_channel_integration(
            repo,
            plan,
            work_dir=tmp_path / "sim",
            game_version="12.1.5",
        )


def test_unrelated_changelog_preface_edit_on_main_fails_preflight_sync(tmp_path, monkeypatch):
    """Content-level guard: main-only CHANGELOG preface edits fail before branch mutation."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    _write_channel_tree(
        repo,
        interface="120100",
        version="1.5.9",
        track="main",
        changelog_versions=[("1.5.9", "### Changed\n- Prior\n")],
        extra_files={"SpectrumFederation/Core.lua": "print('shared')\n"},
    )
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "base")
    _git(repo, "checkout", "-b", "beta")
    (repo / "SpectrumFederation" / "BetaOnly.lua").write_text("return 1\n", encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "beta-only")
    beta_sha = _git(repo, "rev-parse", "HEAD")

    _git(repo, "checkout", "main")
    changelog = (repo / "CHANGELOG.md").read_text(encoding="utf-8")
    (repo / "CHANGELOG.md").write_text(
        changelog.replace(
            "All notable changes to SpectrumFederation will be documented in this file.",
            "Main-only changelog preface that must not sync automatically.",
        ),
        encoding="utf-8",
    )
    _git(repo, "add", "CHANGELOG.md")
    _git(repo, "commit", "-m", "docs: unrelated main CHANGELOG preface edit")
    main_sha = _git(repo, "rev-parse", "HEAD")
    main_tip_before_sim = main_sha
    beta_tip_before_sim = beta_sha

    monkeypatch.setattr(wow, "fetch_github_release", lambda *_a, **_k: None)
    requested = wow.parse_human_game_version("12.1.5")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.5.1",
        live_interface=120105,
        main_interface="120100",
        main_version_raw="1.5.9",
        beta_interface="120100",
        beta_version_raw="1.5.9",
        main_sha=main_sha,
        beta_sha=beta_sha,
        repo="owner/repo",
        token="token",
        repo_path=repo,
    )
    assert plan["main_update_needed"] is True
    assert plan["sync_needed"] is True
    with pytest.raises(RuntimeError, match="unversioned preface"):
        wow.simulate_channel_integration(
            repo,
            plan,
            work_dir=tmp_path / "sim",
            game_version="12.1.5",
        )

    # Preflight must fail before mutating the source repository branches.
    assert _git(repo, "rev-parse", "main") == main_tip_before_sim
    assert _git(repo, "rev-parse", "beta") == beta_tip_before_sim


def test_history_only_sync_does_not_synthesize_beta_changelog_section(tmp_path):
    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]
    _git(repo, "checkout", "beta")
    # Replace the beta compatibility note with a placeholder so a naive rewrite
    # would replace it; history-only sync must leave it alone.
    placeholder_changelog = "\n".join(
        [
            "# Changelog",
            "",
            "## [1.5.11-beta.1] - 2026-10-13",
            "",
            "### Changed",
            "- Infrastructure and tooling updates",
            "",
            "## [1.5.9] - 2026-10-13",
            "",
            "### Changed",
            "- Prior stable release note",
            "",
        ]
    )
    (repo / "CHANGELOG.md").write_text(placeholder_changelog, encoding="utf-8")
    _git(repo, "add", "CHANGELOG.md")
    _git(repo, "commit", "-m", "placeholder beta changelog")
    before = _git(repo, "rev-parse", "HEAD")

    result = wow.integrate_main_into_beta(
        repo,
        main_sha=state["main_sha"],
        beta_interface="120105",
        beta_version="1.5.11-beta.1",
        game_version="12.1.5",
        beta_update_needed=False,
        commit=True,
    )
    assert result["synced"] is True
    assert wow.git_is_ancestor(repo, state["main_sha"], result["commit_sha"])
    changelog = wow.read_git_blob(repo, "HEAD", "CHANGELOG.md")
    assert "## [1.5.10]" in changelog
    assert "Infrastructure and tooling updates" in changelog
    assert "Updated Retail game compatibility to Interface 120105 (12.1.5)." in changelog
    # Placeholder section must not be replaced by a regenerated compatibility note.
    beta_section = changelog.split("## [1.5.11-beta.1]")[1].split("## [")[0]
    assert "Infrastructure and tooling updates" in beta_section
    assert "Updated Retail game compatibility" not in beta_section
    assert _git(repo, "rev-parse", "HEAD") != before


def test_history_sync_plus_missing_release_uses_mutated_publish_source(tmp_path, monkeypatch):
    """Recovery: sync_needed + beta_action=publish must publish the post-sync tip."""
    state = _init_divergent_game_version_repo(tmp_path)
    repo = state["repo"]
    monkeypatch.setattr(wow, "fetch_github_release", lambda *_a, **_k: None)
    requested = wow.parse_human_game_version("12.1.5")
    plan = wow.build_update_plan(
        requested=requested,
        live_game_version="12.1.5.1",
        live_interface=120105,
        main_interface="120105",
        main_version_raw="1.5.10",
        beta_interface="120105",
        beta_version_raw="1.5.11-beta.1",
        main_sha=state["main_sha"],
        beta_sha=state["beta_sha"],
        repo="owner/repo",
        token="token",
        repo_path=repo,
    )
    assert plan["sync_needed"] is True
    assert plan["beta_update_needed"] is False
    assert plan["beta_action"] == "publish"
    assert plan["beta_branch_mutation"] is True
    assert plan["main_action"] in {"none", "publish"}

    workflow = (
        Path(__file__).resolve().parents[1]
        / ".github"
        / "workflows"
        / "update-wow-game-version.yml"
    ).read_text(encoding="utf-8")
    assert "BETA_MUTATION" in workflow
    assert 'BETA_ACTION" == "update" || "$BETA_MUTATION" == "true"' in workflow
    assert "beta_branch_mutation != 'true'" in workflow

    _git(repo, "checkout", "beta")
    result = wow.integrate_main_into_beta(
        repo,
        main_sha=state["main_sha"],
        beta_interface="120105",
        beta_version="1.5.11-beta.1",
        game_version="12.1.5",
        beta_update_needed=False,
        commit=True,
    )
    synced_sha = result["commit_sha"]
    assert synced_sha != state["beta_sha"]
    assert wow.git_is_ancestor(repo, state["main_sha"], synced_sha)
    # Publish source after mutation is the synced tip, not the pre-sync capture.
    assert synced_sha == _git(repo, "rev-parse", "HEAD")
    with pytest.raises(RuntimeError, match="advanced unexpectedly"):
        wow.verify_git_sha(repo, "HEAD", state["beta_sha"], label="beta")
