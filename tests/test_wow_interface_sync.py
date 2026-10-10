from __future__ import annotations

import importlib.util
import json
import subprocess
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
    # Main may retry a channel-matched publish; beta must never publish stable 1.5.8.
    assert plan["main_action"] == "publish"
    assert plan["beta_action"] == "none"
    assert plan["any_work"] is True


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
    assert "group: release-channels" in path.read_text(encoding="utf-8")
    assert wow.ensure_release_channels_concurrency(path) is False


def test_workflow_pins_helpers_and_requires_admin_pat():
    workflow = (
        Path(__file__).resolve().parents[1]
        / ".github"
        / "workflows"
        / "update-wow-game-version.yml"
    ).read_text(encoding="utf-8")
    assert "--materialize-helpers" in workflow
    assert "HELPERS_DIR" in workflow
    assert "secrets.PAT_TOKEN" in workflow
    assert "--assert-no-conflicts" in workflow
    assert "Refuse stable-version beta publish" in workflow
    post_merge = (
        Path(__file__).resolve().parents[1]
        / ".github"
        / "workflows"
        / "post-merge-beta.yml"
    ).read_text(encoding="utf-8")
    assert "chore: bump Interface to" in post_merge
    assert "group: release-channels" in post_merge


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
