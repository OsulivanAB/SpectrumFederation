"""Tests for GitHub/Wago release classification and Wago publishing."""

from __future__ import annotations

import http.client
import importlib.util
import inspect
import io
import json
import subprocess
import sys
import zipfile
from pathlib import Path
from urllib import error as urllib_error

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / ".github" / "scripts"


def _load_script(name):
    module_path = SCRIPTS_DIR / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


publish = _load_script("publish_release")
validate_packaging = _load_script("validate_packaging")


class FakeResponse:
    def __init__(self, status=201, body=b"{}"):
        self.status = status
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


def _plan(tmp_path, **overrides):
    zip_path = tmp_path / "SpectrumFederation-1.5.0-beta.1.zip"
    zip_path.write_bytes(b"zip-bytes")
    values = {
        "project_id": "BNBmnlGx",
        "label": "1.5.0-beta.1",
        "stability": "beta",
        "supported_retail_patch": "12.1.0",
        "patch_match": "exact",
        "changelog": "Beta release 1.5.0-beta.1\n",
        "zip_path": zip_path,
        "endpoint": "https://addons.wago.io/api/projects/BNBmnlGx/version",
    }
    values.update(overrides)
    return publish.WagoPublishPlan(**values)


@pytest.mark.parametrize(
    ("version", "stability", "is_prerelease", "github_kind", "curseforge_type"),
    [
        ("1.4.0", "stable", False, "release", "release"),
        ("1.6.0", "stable", False, "release", "release"),
        ("1.5.0-beta.1", "beta", True, "prerelease", "beta"),
        ("1.6.0-beta.1", "beta", True, "prerelease", "beta"),
        ("1.5.0-BETA.2", "beta", True, "prerelease", "beta"),
        ("1.6.0-BETA.2", "beta", True, "prerelease", "beta"),
        ("1.5.0-alpha.1", "alpha", True, "prerelease", "alpha"),
        ("1.6.0-alpha.1", "alpha", True, "prerelease", "alpha"),
        ("1.5.0-rc.1", "beta", True, "prerelease", "beta"),
        ("1.6.0-rc.1", "beta", True, "prerelease", "beta"),
    ],
)
def test_classify_release_maps_version_to_github_wago_and_curseforge(
    version, stability, is_prerelease, github_kind, curseforge_type
):
    classification = publish.classify_release(version)
    assert classification.wago_stability == stability
    assert classification.is_prerelease is is_prerelease
    assert classification.github_release_kind == github_kind
    assert classification.curseforge_release_type == curseforge_type


def test_classify_release_does_not_treat_alphabet_as_alpha():
    classification = publish.classify_release("1.5.0-alphabet.1")
    assert classification.wago_stability == "stable"
    assert classification.is_prerelease is False
    assert classification.curseforge_release_type == "release"


def test_wago_metadata_includes_required_fields(tmp_path):
    plan = _plan(tmp_path)
    metadata = publish.build_wago_metadata(
        plan.label,
        plan.stability,
        plan.changelog,
        plan.supported_retail_patch,
    )
    assert metadata == {
        "label": "1.5.0-beta.1",
        "stability": "beta",
        "changelog": "Beta release 1.5.0-beta.1\n",
        "supported_retail_patch": "12.1.0",
    }
    assert metadata["label"] == plan.label
    assert plan.project_id == "BNBmnlGx"
    assert plan.zip_path.name.endswith(".zip")
    assert "release.json" not in plan.zip_path.name


def test_get_wago_project_id_reads_parent_toc(tmp_path, monkeypatch):
    addon = tmp_path / "SpectrumFederation"
    addon.mkdir()
    (addon / "SpectrumFederation.toc").write_text(
        "## Version: 1.5.0-beta.1\n## X-Wago-ID: BNBmnlGx\n",
        encoding="utf-8",
    )
    monkeypatch.chdir(tmp_path)
    assert publish.get_wago_project_id("SpectrumFederation") == "BNBmnlGx"


def test_select_wago_retail_patch_requires_exact_match():
    assert publish.select_wago_retail_patch("12.1.0", ["12.0.1", "12.1.0"]) == (
        "12.1.0",
        "exact",
    )
    with pytest.raises(ValueError, match="does not currently advertise Retail patch '12.1.5'"):
        publish.select_wago_retail_patch("12.1.5", ["12.0.1", "12.1.0"])


def test_resolve_supported_retail_patch_fails_without_catalog():
    with pytest.raises(ValueError, match="Requested patch '12.1.0' cannot be verified"):
        publish.resolve_supported_retail_patch(120100, game_data=None)


def test_interface_to_retail_patch_uses_blizzard_helper():
    assert publish.interface_to_retail_patch("120100") == "12.1.0"
    assert publish.interface_to_retail_patch(120001) == "12.0.1"


def test_missing_wago_api_key_fails_real_publish(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv("WAGO_API_KEY", raising=False)
    monkeypatch.setenv("WAGO_API_SECRET", "legacy-webhook-secret")
    result = publish.publish_to_wago(_plan(tmp_path), dry_run=False)
    captured = capsys.readouterr()
    assert result is None
    assert "WAGO_API_KEY is not set" in captured.out
    assert "legacy GitHub webhook signing secret" in captured.out
    assert "legacy-webhook-secret" not in captured.out
    assert "legacy-webhook-secret" not in captured.err


def test_dry_run_does_not_require_wago_api_key(tmp_path, monkeypatch):
    monkeypatch.delenv("WAGO_API_KEY", raising=False)
    monkeypatch.setenv("WAGO_API_SECRET", "legacy-webhook-secret")
    called = {"urlopen": False}

    def fake_urlopen(request, timeout=None):
        called["urlopen"] = True
        raise AssertionError("dry-run must not call Wago")

    result = publish.publish_to_wago(
        _plan(tmp_path),
        dry_run=True,
        opener=fake_urlopen,
    )
    assert result == "dry-run"
    assert called["urlopen"] is False


def test_wago_auth_uses_api_key_not_webhook_secret(tmp_path, monkeypatch):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")
    monkeypatch.setenv("WAGO_API_SECRET", "legacy-webhook-secret")
    captured = {}

    def fake_urlopen(request, timeout=None):
        captured["authorization"] = request.get_header("Authorization")
        captured["body"] = request.data
        captured["user_agent"] = request.get_header("User-agent") or request.get_header("User-Agent")
        return FakeResponse(201, b'{"id":"abc"}')

    result = publish.publish_to_wago(_plan(tmp_path), opener=fake_urlopen)
    assert result == "uploaded"
    assert captured["authorization"] == "Bearer developer-key-123"
    assert captured["user_agent"] == publish.WAGO_USER_AGENT
    assert b"legacy-webhook-secret" not in captured["body"]
    assert b"developer-key-123" not in captured["body"]
    metadata = json.loads(captured["body"].split(b"\r\n\r\n", 1)[1].split(b"\r\n")[0])
    assert metadata["stability"] == "beta"
    assert metadata["supported_retail_patch"] == "12.1.0"


def test_successful_wago_upload(tmp_path, monkeypatch):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")
    result = publish.publish_to_wago(
        _plan(tmp_path),
        opener=lambda request, timeout=None: FakeResponse(201, b"{}"),
    )
    assert result == "uploaded"


def test_wago_authentication_failure(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")

    def fake_urlopen(request, timeout=None):
        raise urllib_error.HTTPError(
            request.full_url,
            401,
            "Unauthorized",
            hdrs=None,
            fp=io.BytesIO(b'{"message":"invalid token"}'),
        )

    result = publish.publish_to_wago(_plan(tmp_path), opener=fake_urlopen)
    captured = capsys.readouterr()
    assert result is None
    assert "authentication failed" in captured.out
    assert "developer-key-123" not in captured.out
    assert "Bearer <redacted>" in captured.out
    assert "Bearer developer-key-123" not in captured.out


def test_wago_validation_failure(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")

    def fake_urlopen(request, timeout=None):
        raise urllib_error.HTTPError(
            request.full_url,
            422,
            "Unprocessable Entity",
            hdrs=None,
            fp=io.BytesIO(b'{"message":"unsupported retail patch"}'),
        )

    result = publish.publish_to_wago(_plan(tmp_path), opener=fake_urlopen)
    captured = capsys.readouterr()
    assert result is None
    assert "rejected the release metadata" in captured.out
    assert "unsupported retail patch" in captured.out


def test_wago_server_error(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")

    def fake_urlopen(request, timeout=None):
        raise urllib_error.HTTPError(
            request.full_url,
            503,
            "Service Unavailable",
            hdrs=None,
            fp=io.BytesIO(b'{"message":"try again later"}'),
        )

    result = publish.publish_to_wago(_plan(tmp_path), opener=fake_urlopen)
    captured = capsys.readouterr()
    assert result is None
    assert "server error" in captured.out


def test_wago_duplicate_version_is_success(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")

    def fake_urlopen(request, timeout=None):
        raise urllib_error.HTTPError(
            request.full_url,
            409,
            "Conflict",
            hdrs=None,
            fp=io.BytesIO(b'{"message":"version already exists"}'),
        )

    result = publish.publish_to_wago(_plan(tmp_path), opener=fake_urlopen)
    captured = capsys.readouterr()
    assert result == "already-exists"
    assert "already has this version" in captured.out


def test_is_existing_wago_release_requires_explicit_duplicate_text():
    assert publish.is_existing_wago_release(409, '{"message":"version already exists"}') is True
    assert publish.is_existing_wago_release(409, "This label already exists on the project") is True
    assert publish.is_existing_wago_release(409, "") is False
    assert publish.is_existing_wago_release(409, "{}") is False
    assert publish.is_existing_wago_release(409, '{"message":"conflict"}') is False
    assert publish.is_existing_wago_release(409, "Conflict") is False
    assert publish.is_existing_wago_release(409, '{"error":"duplicate"}') is False


def test_wago_empty_409_is_not_treated_as_success(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")

    def fake_urlopen(request, timeout=None):
        raise urllib_error.HTTPError(
            request.full_url,
            409,
            "Conflict",
            hdrs=None,
            fp=io.BytesIO(b""),
        )

    result = publish.publish_to_wago(_plan(tmp_path), opener=fake_urlopen)
    captured = capsys.readouterr()
    assert result is None
    assert "without a clear already-exists indication" in captured.out


def test_wago_generic_conflict_409_is_not_treated_as_success(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")

    def fake_urlopen(request, timeout=None):
        raise urllib_error.HTTPError(
            request.full_url,
            409,
            "Conflict",
            hdrs=None,
            fp=io.BytesIO(b'{"message":"conflict"}'),
        )

    result = publish.publish_to_wago(_plan(tmp_path), opener=fake_urlopen)
    captured = capsys.readouterr()
    assert result is None
    assert "without a clear already-exists indication" in captured.out
    assert "already has this version" not in captured.out


def test_wago_generic_400_is_not_treated_as_duplicate(tmp_path, monkeypatch):
    monkeypatch.setenv("WAGO_API_KEY", "developer-key-123")

    def fake_urlopen(request, timeout=None):
        raise urllib_error.HTTPError(
            request.full_url,
            400,
            "Bad Request",
            hdrs=None,
            fp=io.BytesIO(b'{"message":"malformed metadata"}'),
        )

    assert publish.publish_to_wago(_plan(tmp_path), opener=fake_urlopen) is None


def test_logged_failures_redact_credentials():
    leaked = (
        "authorization: Bearer developer-key-123\n"
        "WAGO_API_KEY=developer-key-123\n"
        "WAGO_API_SECRET=legacy-webhook-secret\n"
        "Bearer developer-key-123\n"
        "X-Api-Token: curse-token-123\n"
        "CURSEFORGE_API_TOKEN=curse-token-123"
    )
    sanitized = publish.sanitize_output(leaked)
    assert "developer-key-123" not in sanitized
    assert "legacy-webhook-secret" not in sanitized
    assert "curse-token-123" not in sanitized
    assert "Bearer ***" in sanitized
    assert "X-Api-Token: ***" in sanitized or "x-api-token: ***" in sanitized.lower()
    assert "WAGO_API_KEY=" in sanitized
    assert "CURSEFORGE_API_TOKEN=" in sanitized


def test_github_dry_run_does_not_invoke_gh(monkeypatch, tmp_path):
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("GH_TOKEN", raising=False)
    zip_path = tmp_path / "addon.zip"
    json_path = tmp_path / "release.json"
    notes_path = tmp_path / "notes.md"
    zip_path.write_bytes(b"zip")
    json_path.write_text("{}", encoding="utf-8")
    notes_path.write_text("notes", encoding="utf-8")

    def fail_run(*args, **kwargs):
        raise AssertionError("dry-run must not invoke gh")

    monkeypatch.setattr(publish.subprocess, "run", fail_run)
    classification = publish.classify_release("1.5.0-beta.1")
    result = publish.create_github_release(
        "1.5.0-beta.1",
        zip_path,
        json_path,
        "OsulivanAB/SpectrumFederation",
        classification,
        notes_path,
        dry_run=True,
    )
    assert result == "dry-run"


def test_github_create_uses_prerelease_for_beta(monkeypatch, tmp_path):
    monkeypatch.setenv("GITHUB_TOKEN", "github-token")
    zip_path = tmp_path / "addon.zip"
    json_path = tmp_path / "release.json"
    notes_path = tmp_path / "notes.md"
    zip_path.write_bytes(b"zip")
    json_path.write_text("{}", encoding="utf-8")
    notes_path.write_text("notes", encoding="utf-8")
    commands = []

    def fake_run(cmd, **kwargs):
        commands.append(list(cmd))
        return type("Result", (), {"stdout": "created", "returncode": 0})()

    monkeypatch.setattr(publish, "release_exists", lambda tag_name, env: False)
    monkeypatch.setattr(publish.subprocess, "run", fake_run)
    result = publish.create_github_release(
        "1.5.0-beta.1",
        zip_path,
        json_path,
        "OsulivanAB/SpectrumFederation",
        publish.classify_release("1.5.0-beta.1"),
        notes_path,
        dry_run=False,
    )
    assert result == "created"
    assert commands[0][:3] == ["gh", "release", "create"]
    assert "--prerelease" in commands[0]
    assert str(zip_path) in commands[0]
    assert str(json_path) in commands[0]


def test_github_stable_release_is_not_prerelease(monkeypatch, tmp_path):
    monkeypatch.setenv("GITHUB_TOKEN", "github-token")
    zip_path = tmp_path / "addon.zip"
    json_path = tmp_path / "release.json"
    notes_path = tmp_path / "notes.md"
    zip_path.write_bytes(b"zip")
    json_path.write_text("{}", encoding="utf-8")
    notes_path.write_text("notes", encoding="utf-8")
    commands = []

    def fake_run(cmd, **kwargs):
        commands.append(list(cmd))
        return type("Result", (), {"stdout": "created", "returncode": 0})()

    monkeypatch.setattr(publish, "release_exists", lambda tag_name, env: False)
    monkeypatch.setattr(publish.subprocess, "run", fake_run)
    result = publish.create_github_release(
        "1.5.0",
        zip_path,
        json_path,
        "OsulivanAB/SpectrumFederation",
        publish.classify_release("1.5.0"),
        notes_path,
        dry_run=False,
    )
    assert result == "created"
    assert "--prerelease" not in commands[0]


def test_github_existing_release_is_updated(monkeypatch, tmp_path):
    monkeypatch.setenv("GITHUB_TOKEN", "github-token")
    zip_path = tmp_path / "addon.zip"
    json_path = tmp_path / "release.json"
    notes_path = tmp_path / "notes.md"
    zip_path.write_bytes(b"zip")
    json_path.write_text("{}", encoding="utf-8")
    notes_path.write_text("notes", encoding="utf-8")
    commands = []

    def fake_run(cmd, **kwargs):
        commands.append(list(cmd))
        return type("Result", (), {"stdout": "", "returncode": 0})()

    monkeypatch.setattr(publish, "release_exists", lambda tag_name, env: True)
    monkeypatch.setattr(publish.subprocess, "run", fake_run)
    result = publish.create_github_release(
        "1.5.0-beta.1",
        zip_path,
        json_path,
        "OsulivanAB/SpectrumFederation",
        publish.classify_release("1.5.0-beta.1"),
        notes_path,
        dry_run=False,
    )
    assert result == "updated"
    assert commands[0][:3] == ["gh", "release", "edit"]
    assert commands[1][:3] == ["gh", "release", "upload"]
    assert "--clobber" in commands[1]


def test_create_release_json_wowup_shape(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    path = publish.create_release_json("1.5.0", 120100, "SpectrumFederation", "SpectrumFederation-1.5.0.zip")
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["releases"][0]["filename"] == "SpectrumFederation-1.5.0.zip"
    assert payload["releases"][0]["metadata"][0] == {
        "flavor": "mainline",
        "interface": 120100,
    }


def test_build_wago_plan_uses_toc_id_and_notes(tmp_path, monkeypatch):
    addon = tmp_path / "SpectrumFederation"
    addon.mkdir()
    (addon / "SpectrumFederation.toc").write_text(
        "## Interface: 120100\n## Version: 1.5.0-beta.1\n## X-Wago-ID: BNBmnlGx\n",
        encoding="utf-8",
    )
    zip_path = tmp_path / "SpectrumFederation-1.5.0-beta.1.zip"
    zip_path.write_bytes(b"zip")
    monkeypatch.chdir(tmp_path)
    classification = publish.classify_release("1.5.0-beta.1")
    plan = publish.build_wago_publish_plan(
        version="1.5.0-beta.1",
        classification=classification,
        addon_name="SpectrumFederation",
        interface=120100,
        zip_path=zip_path,
        changelog="Beta release 1.5.0-beta.1\n",
        game_data={"patches": {"retail": ["12.1.0", "12.0.1"]}},
    )
    assert plan is not None
    assert plan.project_id == "BNBmnlGx"
    assert plan.label == "1.5.0-beta.1"
    assert plan.stability == "beta"
    assert plan.supported_retail_patch == "12.1.0"
    assert plan.changelog.startswith("Beta release")
    assert plan.zip_path == zip_path


def test_validate_packaging_requires_matching_child_wago_id(tmp_path, capsys):
    parent_toc = tmp_path / "parent.toc"
    child_toc = tmp_path / "child.toc"
    parent_toc.write_text("## X-Wago-ID: BNBmnlGx\n", encoding="utf-8")
    child_toc.write_text("## Version: 1.4.0\n", encoding="utf-8")
    assert validate_packaging.validate_wago_project_id(parent_toc, child_toc) is False
    assert "No '## X-Wago-ID:' line found" in capsys.readouterr().out

    child_toc.write_text("## X-Wago-ID: OtherId1\n", encoding="utf-8")
    assert validate_packaging.validate_wago_project_id(parent_toc, child_toc) is False
    assert "does not match parent" in capsys.readouterr().out

    child_toc.write_text("## X-Wago-ID: BNBmnlGx\n", encoding="utf-8")
    assert validate_packaging.validate_wago_project_id(parent_toc, child_toc) is True


def test_pkgmeta_must_lift_child_addons_to_zip_root(tmp_path, capsys):
    names = ["SpectrumFederation", *validate_packaging.CHILD_ADDON_NAMES]
    parent_only = {
        "SpectrumFederation/SpectrumFederation": "SpectrumFederation",
    }
    assert validate_packaging.validate_pkgmeta_move_mapping(parent_only, names) is False
    output = capsys.readouterr().out
    for child in validate_packaging.CHILD_ADDON_NAMES:
        assert f"SpectrumFederation/{child}" in output

    complete = {
        "SpectrumFederation/SpectrumFederation": "SpectrumFederation",
        **{
            f"SpectrumFederation/{child}": child
            for child in validate_packaging.CHILD_ADDON_NAMES
        },
    }
    assert validate_packaging.validate_pkgmeta_move_mapping(complete, names) is True


def test_repo_pkgmeta_lifts_packaged_child_addons():
    names = validate_packaging.packaged_addon_names("SpectrumFederation")
    pkgmeta = Path("pkgmeta.yaml")
    assert validate_packaging.validate_pkgmeta_addon_folders(pkgmeta, names) is True
    moves = validate_packaging.parse_pkgmeta_move_folders(pkgmeta)
    for child in names[1:]:
        assert moves[f"SpectrumFederation/{child}"] == child


def test_missing_pkgmeta_is_rejected(tmp_path, capsys):
    names = ["SpectrumFederation", *validate_packaging.CHILD_ADDON_NAMES]
    missing = tmp_path / "pkgmeta.yaml"
    assert validate_packaging.validate_pkgmeta_addon_folders(missing, names) is False
    assert "pkgmeta.yaml not found" in capsys.readouterr().out


def test_legacy_webhook_secret_is_never_read_for_auth():
    source = Path(publish.__file__).read_text(encoding="utf-8")
    assert "os.environ.get(WAGO_LEGACY_WEBHOOK_SECRET_ENV)" not in source
    assert 'os.environ.get("WAGO_API_SECRET")' not in source
    assert "WAGO_API_SECRET" in source


CHANGELOG_FIXTURE = """# Changelog

## [1.5.0-beta.1] - 2026-09-04

### Changed
- Beta notes

## [Unreleased - Beta]

### Changed
- Unreleased beta notes

## [1.5.0-alpha.1] - 2026-09-03

### Changed
- Alpha notes

## [1.5.0-rc.1] - 2026-09-02

### Changed
- RC notes

## [1.4.0] - 2026-09-01

### Changed
- Stable notes
"""


def test_changelog_beta_uses_exact_heading_then_unreleased(tmp_path, monkeypatch):
    (tmp_path / "CHANGELOG.md").write_text(CHANGELOG_FIXTURE, encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    exact = publish.get_changelog_for_version("1.5.0-beta.1")
    assert "## [1.5.0-beta.1]" in exact
    assert "Beta notes" in exact
    assert "Unreleased beta notes" not in exact

    missing_beta = publish.get_changelog_for_version("1.5.0-BETA.2")
    assert "## [Unreleased - Beta]" in missing_beta
    assert "Unreleased beta notes" in missing_beta


def test_released_1_5_0_notes_include_linked_characters():
    notes = publish.get_changelog_for_version("1.5.0")
    assert notes is not None
    assert "## [1.5.0]" in notes
    assert "Linked Characters" in notes
    assert "CHARACTER_LINK" in notes
    changelog = Path("CHANGELOG.md").read_text(encoding="utf-8")
    assert "## [1.5.0-beta.1]" not in changelog
    assert notes.count("## [") == 1


def test_released_1_5_1_notes_include_sync_nack_warning_dedupe():
    notes = publish.get_changelog_for_version("1.5.1")
    assert notes is not None
    assert "## [1.5.1]" in notes
    assert "incompatibility warnings print once" in notes
    assert notes.count("## [") == 1


def test_changelog_alpha_and_rc_use_exact_heading_only(tmp_path, monkeypatch):
    (tmp_path / "CHANGELOG.md").write_text(CHANGELOG_FIXTURE, encoding="utf-8")
    monkeypatch.chdir(tmp_path)

    alpha = publish.get_changelog_for_version("1.5.0-alpha.1")
    assert "## [1.5.0-alpha.1]" in alpha
    assert "Alpha notes" in alpha
    assert "Unreleased beta notes" not in alpha

    rc = publish.get_changelog_for_version("1.5.0-rc.1")
    assert "## [1.5.0-rc.1]" in rc
    assert "RC notes" in rc
    assert "Unreleased beta notes" not in rc

    assert publish.get_changelog_for_version("1.5.0-alpha.2") is None
    assert publish.get_changelog_for_version("1.5.0-rc.2") is None


def test_build_wago_plan_fails_when_patch_is_not_advertised(tmp_path, monkeypatch, capsys):
    addon = tmp_path / "SpectrumFederation"
    addon.mkdir()
    (addon / "SpectrumFederation.toc").write_text(
        "## X-Wago-ID: BNBmnlGx\n",
        encoding="utf-8",
    )
    zip_path = tmp_path / "addon.zip"
    zip_path.write_bytes(b"zip")
    monkeypatch.chdir(tmp_path)
    plan = publish.build_wago_publish_plan(
        version="1.5.0",
        classification=publish.classify_release("1.5.0"),
        addon_name="SpectrumFederation",
        interface=120105,
        zip_path=zip_path,
        changelog="notes",
        game_data={"patches": {"retail": ["12.1.0", "12.0.1"]}},
    )
    captured = capsys.readouterr()
    assert plan is None
    assert "does not currently advertise Retail patch '12.1.5'" in captured.out


def _orchestrator_args(tmp_path, *, version="1.5.0-beta.1"):
    zip_path = tmp_path / f"SpectrumFederation-{version}.zip"
    json_path = tmp_path / "release.json"
    notes_path = tmp_path / "notes.md"
    zip_path.write_bytes(b"zip")
    json_path.write_text("{}", encoding="utf-8")
    notes_path.write_text("notes", encoding="utf-8")
    return {
        "version": version,
        "classification": publish.classify_release(version),
        "addon_name": "SpectrumFederation",
        "interface": 120100,
        "zip_path": zip_path,
        "json_path": json_path,
        "notes": "Beta release notes",
        "notes_path": notes_path,
        "repo": "OsulivanAB/SpectrumFederation",
    }


def test_live_github_runs_before_external_catalog_lookup(tmp_path, monkeypatch, capsys):
    addon = tmp_path / "SpectrumFederation"
    addon.mkdir()
    (addon / "SpectrumFederation.toc").write_text(
        "## X-Wago-ID: BNBmnlGx\n## X-Curse-Project-ID: 1445757\n",
        encoding="utf-8",
    )
    monkeypatch.chdir(tmp_path)
    order = []

    def fake_github(*args, **kwargs):
        order.append("github")
        return "created"

    def fake_curseforge(**kwargs):
        order.append("curseforge")
        return None

    def fake_catalog():
        order.append("wago-catalog")
        return None

    def fail_upload(*args, **kwargs):
        raise AssertionError("external upload must not run when plan resolution fails")

    monkeypatch.setattr(publish, "create_github_release", fake_github)
    monkeypatch.setattr(publish, "resolve_curseforge_publish_plan", fake_curseforge)
    monkeypatch.setattr(publish, "fetch_wago_game_data", fake_catalog)
    monkeypatch.setattr(publish, "publish_to_wago", fail_upload)
    monkeypatch.setattr(publish, "publish_to_curseforge", fail_upload)

    result = publish.publish_github_then_external(**_orchestrator_args(tmp_path), dry_run=False)
    captured = capsys.readouterr()
    assert result is False
    assert order == ["github", "curseforge", "wago-catalog"]
    assert "Destination results: GitHub succeeded, CurseForge failed, Wago failed." in captured.out
    assert "Do not delete GitHub, CurseForge, or Wago releases" in captured.out


def test_live_wago_plan_failure_does_not_block_github(tmp_path, monkeypatch, capsys):
    github_calls = []

    def fake_github(*args, **kwargs):
        github_calls.append(kwargs.get("dry_run"))
        return "updated"

    def fail_plan(**kwargs):
        print("::error ::Could not load Wago's Retail patch catalog")
        return None

    def fail_upload(*args, **kwargs):
        raise AssertionError("Wago upload must not run")

    def fake_curseforge(**kwargs):
        return None

    monkeypatch.setattr(publish, "create_github_release", fake_github)
    monkeypatch.setattr(publish, "resolve_curseforge_publish_plan", fake_curseforge)
    monkeypatch.setattr(publish, "resolve_wago_publish_plan", fail_plan)
    monkeypatch.setattr(publish, "publish_to_wago", fail_upload)
    monkeypatch.setattr(publish, "publish_to_curseforge", fail_upload)

    result = publish.publish_github_then_external(**_orchestrator_args(tmp_path), dry_run=False)
    captured = capsys.readouterr()
    assert result is False
    assert github_calls == [False]
    assert "GitHub release action: updated" in captured.out
    assert "Destination results: GitHub succeeded, CurseForge failed, Wago failed." in captured.out
    assert "Do not delete GitHub, CurseForge, or Wago releases" in captured.out


def test_dry_run_validates_external_plans_before_simulated_github(tmp_path, monkeypatch, capsys):
    order = []

    def curseforge_plan(**kwargs):
        order.append("curseforge-plan")
        return None

    def fail_plan(**kwargs):
        order.append("wago-plan")
        return None

    def fake_github(*args, **kwargs):
        order.append("github")
        return "dry-run"

    monkeypatch.setattr(publish, "resolve_curseforge_publish_plan", curseforge_plan)
    monkeypatch.setattr(publish, "resolve_wago_publish_plan", fail_plan)
    monkeypatch.setattr(publish, "create_github_release", fake_github)

    result = publish.publish_github_then_external(**_orchestrator_args(tmp_path), dry_run=True)
    captured = capsys.readouterr()
    assert result is False
    assert order == ["curseforge-plan", "wago-plan"]
    assert "GitHub release succeeded" not in captured.out


def _write_packaged_tocs(root, version):
    names = ["SpectrumFederation", *validate_packaging.CHILD_ADDON_NAMES]
    for name in names:
        addon_dir = root / name
        addon_dir.mkdir()
        (addon_dir / f"{name}.toc").write_text(
            f"## Version: {version}\n## X-Wago-ID: BNBmnlGx\n",
            encoding="utf-8",
        )
    return names


def test_create_addon_zip_uses_canonical_packaging_command(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    names = _write_packaged_tocs(tmp_path, "1.5.3-beta.1")
    captured = {}

    def fake_run(cmd, check=True, capture_output=True):
        captured["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(publish.subprocess, "run", fake_run)
    zip_path = publish.create_addon_zip("SpectrumFederation", "1.5.3-beta.1")
    expected = validate_packaging.zip_create_command(
        Path("build") / "SpectrumFederation-1.5.3-beta.1.zip",
        names,
    )
    assert captured["cmd"] == expected
    assert zip_path == Path("build") / "SpectrumFederation-1.5.3-beta.1.zip"
    assert expected[expected.index("-x") + 1 :] == validate_packaging.ZIP_EXCLUDES
    for child in validate_packaging.CHILD_ADDON_NAMES:
        assert child in captured["cmd"]


def test_create_test_zip_uses_the_same_canonical_command(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    names = _write_packaged_tocs(tmp_path, "1.5.3-beta.1")
    captured = {}

    def fake_run(cmd, check=True, capture_output=True):
        captured["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(validate_packaging.subprocess, "run", fake_run)
    ok, zip_path = validate_packaging.create_test_zip(names)
    expected = validate_packaging.zip_create_command(
        Path("build") / "SpectrumFederation-validation.zip",
        names,
    )
    assert ok is True
    assert captured["cmd"] == expected
    assert zip_path == Path("build") / "SpectrumFederation-validation.zip"


def test_requested_version_matches_packaged_parent_and_child_tocs(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    _write_packaged_tocs(tmp_path, "1.5.3-beta.1")
    assert publish.requested_version_matches_packaged_toc(
        "SpectrumFederation", "1.5.3-beta.1"
    )
    assert not publish.requested_version_matches_packaged_toc(
        "SpectrumFederation", "1.5.3-beta.2"
    )
    captured = capsys.readouterr()
    assert "does not match packaged parent TOC" in captured.out


def test_requested_version_rejects_child_toc_mismatch(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    _write_packaged_tocs(tmp_path, "1.5.3-beta.1")
    child = validate_packaging.CHILD_ADDON_NAMES[0]
    (tmp_path / child / f"{child}.toc").write_text(
        "## Version: 1.5.3-beta.2\n",
        encoding="utf-8",
    )
    assert not publish.requested_version_matches_packaged_toc(
        "SpectrumFederation", "1.5.3-beta.1"
    )
    captured = capsys.readouterr()
    assert child in captured.out
    assert "1.5.3-beta.2" in captured.out


def test_main_refuses_to_zip_when_requested_version_differs_from_toc(
    tmp_path, monkeypatch, capsys
):
    monkeypatch.chdir(tmp_path)
    _write_packaged_tocs(tmp_path, "1.5.3-beta.2")
    zipped = []
    monkeypatch.setattr(
        publish,
        "create_addon_zip",
        lambda *args, **kwargs: zipped.append(args) or Path("missing.zip"),
    )
    monkeypatch.setattr(
        sys,
        "argv",
        ["publish_release.py", "1.5.3-beta.1", "--interface", "120100"],
    )
    with pytest.raises(SystemExit) as exc:
        publish.main()
    captured = capsys.readouterr()
    assert exc.value.code == 1
    assert zipped == []
    assert "does not match packaged parent TOC" in captured.out


def test_publisher_does_not_hardcode_child_addons_or_zip_excludes():
    create_zip_src = inspect.getsource(publish.create_addon_zip)
    assert "zip_create_command" in create_zip_src
    assert "packaged_addon_names" in create_zip_src
    assert "CursedSurgeTracker" not in create_zip_src
    assert "RCLootCouncilIntegration" not in create_zip_src
    assert "AGENTS.md" not in create_zip_src
    assert "*.git*" not in create_zip_src


def _curseforge_plan(tmp_path, **overrides):
    zip_path = tmp_path / "SpectrumFederation-1.6.0-beta.1.zip"
    zip_path.write_bytes(b"zip-bytes")
    values = {
        "project_id": "1445757",
        "version": "1.6.0-beta.1",
        "release_type": "beta",
        "retail_patch": "12.1.0",
        "game_version_id": 16519,
        "game_version_name": "12.1.0",
        "patch_match": "exact",
        "changelog": "Beta release 1.6.0-beta.1\n",
        "changelog_source": "CHANGELOG.md",
        "zip_path": zip_path,
        "endpoint": "https://wow.curseforge.com/api/projects/1445757/upload-file",
        "action": "upload",
    }
    values.update(overrides)
    return publish.CurseForgePublishPlan(**values)


def _curseforge_versions():
    return [
        {"id": 11, "gameVersionTypeID": 67408, "name": "12.1.0"},
        {"id": 22, "gameVersionTypeID": 900, "name": "12.1.0"},
        {"id": 16519, "gameVersionTypeID": 517, "name": "12.1.0"},
        {"id": 16984, "gameVersionTypeID": 517, "name": "12.1.5"},
        {"id": 14029, "gameVersionTypeID": 67408, "name": "1.15.8"},
    ]


def _curseforge_version_types():
    return [
        {"id": 517, "name": "World of Warcraft", "slug": "world-of-warcraft"},
        {"id": 67408, "name": "WoW Classic", "slug": "wow-classic"},
        {"id": 900, "name": "World of Warcraft Public Test", "slug": "world-of-warcraft-public-test"},
    ]


def _write_curseforge_toc(tmp_path, project_id="1445757"):
    addon = tmp_path / "SpectrumFederation"
    addon.mkdir()
    (addon / "SpectrumFederation.toc").write_text(
        f"## Version: 1.6.0-beta.1\n## X-Wago-ID: BNBmnlGx\n## X-Curse-Project-ID: {project_id}\n",
        encoding="utf-8",
    )


def _http_error(request, status, body):
    payload = body if isinstance(body, bytes) else body.encode()
    return urllib_error.HTTPError(
        request.full_url,
        status,
        "error",
        hdrs=None,
        fp=io.BytesIO(payload),
    )


def test_parent_toc_declares_curseforge_project_id():
    text = Path("SpectrumFederation/SpectrumFederation.toc").read_text(encoding="utf-8")
    assert "## X-Curse-Project-ID: 1445757" in text


def test_release_workflows_pass_curseforge_token():
    beta = Path(".github/workflows/post-merge-beta.yml").read_text(encoding="utf-8")
    promote = Path(".github/workflows/promote-beta-to-main.yml").read_text(encoding="utf-8")
    secret = "CURSEFORGE_API_TOKEN: ${{ secrets.CURSEFORGE_API_TOKEN }}"
    assert beta.count(secret) == 1
    assert promote.count(secret) == 1
    assert "--dry-run" in promote


def test_publisher_does_not_hardcode_curseforge_game_version_id():
    source = Path(".github/scripts/publish_release.py").read_text(encoding="utf-8")
    assert "16519" not in source
    assert "CURSEFORGE_API_TOKEN" in source
    assert source.count("CURSEFORGE_API_TOKEN") >= 1
    assert "x-api-key" not in source.lower()


def test_get_curseforge_project_id_reads_parent_toc(tmp_path, monkeypatch):
    _write_curseforge_toc(tmp_path)
    monkeypatch.chdir(tmp_path)
    assert publish.get_curseforge_project_id("SpectrumFederation") == "1445757"


def test_missing_curseforge_project_id_fails(tmp_path, monkeypatch, capsys):
    addon = tmp_path / "SpectrumFederation"
    addon.mkdir()
    (addon / "SpectrumFederation.toc").write_text("## X-Wago-ID: BNBmnlGx\n", encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    assert publish.get_curseforge_project_id("SpectrumFederation") is None
    assert "Missing ## X-Curse-Project-ID" in capsys.readouterr().out


def test_invalid_curseforge_project_id_fails(tmp_path, monkeypatch, capsys):
    _write_curseforge_toc(tmp_path, project_id="BNBmnlGx")
    monkeypatch.chdir(tmp_path)
    assert publish.get_curseforge_project_id("SpectrumFederation") is None
    assert "not a numeric CurseForge project ID" in capsys.readouterr().out


def test_validate_curseforge_project_id_rules(tmp_path, capsys):
    toc = tmp_path / "SpectrumFederation.toc"
    toc.write_text("## X-Wago-ID: BNBmnlGx\n", encoding="utf-8")
    assert validate_packaging.validate_curseforge_project_id(toc) is False
    assert "X-Curse-Project-ID" in capsys.readouterr().out
    toc.write_text("## X-Curse-Project-ID: 0\n", encoding="utf-8")
    assert validate_packaging.validate_curseforge_project_id(toc) is False
    toc.write_text("## X-Curse-Project-ID: 1445757\n", encoding="utf-8")
    assert validate_packaging.validate_curseforge_project_id(toc) is True


def test_select_curseforge_retail_game_version_requires_exact_retail_patch():
    selected = publish.select_curseforge_retail_game_version(
        "12.1.0",
        _curseforge_versions(),
        _curseforge_version_types(),
    )
    assert selected == (16519, "12.1.0", "exact")
    with pytest.raises(ValueError, match="does not currently advertise Retail patch '12.1.7'"):
        publish.select_curseforge_retail_game_version(
            "12.1.7",
            _curseforge_versions(),
            _curseforge_version_types(),
        )


def test_select_curseforge_retail_game_version_rejects_name_without_retail_type():
    versions = [
        {"id": 1, "gameVersionTypeID": 10, "name": "12.1.0"},
        {"id": 2, "gameVersionTypeID": 11, "name": "12.1.0"},
    ]
    with pytest.raises(ValueError, match="Retail version type could not be identified"):
        publish.select_curseforge_retail_game_version("12.1.0", versions, None)


def test_select_curseforge_retail_game_version_accepts_retail_label():
    types = [
        {"id": 517, "name": "Retail", "slug": "wow_retail"},
        {"id": 900, "name": "Retail PTR", "slug": "wow-retail-ptr"},
    ]
    selected = publish.select_curseforge_retail_game_version(
        "12.1.0",
        _curseforge_versions(),
        types,
    )
    assert selected == (16519, "12.1.0", "exact")


def test_select_curseforge_retail_game_version_rejects_unique_ptr_name():
    versions = [{"id": 17000, "gameVersionTypeID": 900, "name": "12.2.0"}]
    ptr_types = [{"id": 900, "name": "Retail PTR", "slug": "wow-retail-ptr"}]
    with pytest.raises(ValueError, match="Retail version type could not be identified"):
        publish.select_curseforge_retail_game_version("12.2.0", versions, None)
    with pytest.raises(ValueError, match="Retail version type could not be identified"):
        publish.select_curseforge_retail_game_version("12.2.0", versions, ptr_types)


def test_build_curseforge_plan_does_not_fall_back_to_older_patch(tmp_path, monkeypatch, capsys):
    _write_curseforge_toc(tmp_path)
    monkeypatch.chdir(tmp_path)
    zip_path = tmp_path / "addon.zip"
    zip_path.write_bytes(b"zip")
    plan = publish.build_curseforge_publish_plan(
        version="1.6.0-beta.1",
        classification=publish.classify_release("1.6.0-beta.1"),
        addon_name="SpectrumFederation",
        interface=120100,
        zip_path=zip_path,
        changelog="notes",
        require_game_version=True,
        versions=[{"id": 13924, "gameVersionTypeID": 517, "name": "12.0.0"}],
        version_types=[{"id": 517, "name": "Retail", "slug": "wow-retail"}],
    )
    assert plan is None
    assert "does not currently advertise Retail patch '12.1.0'" in capsys.readouterr().out


def test_curseforge_metadata_uses_canonical_zip_fields(tmp_path):
    plan = _curseforge_plan(tmp_path)
    metadata = publish.build_curseforge_metadata(
        plan.version,
        plan.release_type,
        plan.changelog,
        plan.game_version_id,
        plan.game_version_name,
    )
    assert metadata == {
        "changelog": "Beta release 1.6.0-beta.1\n",
        "changelogType": "markdown",
        "displayName": "1.6.0-beta.1",
        "gameVersions": [16519],
        "gameVersionNames": ["12.1.0"],
        "releaseType": "beta",
    }


def test_missing_curseforge_token_fails_live_upload(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv("CURSEFORGE_API_TOKEN", raising=False)
    result = publish.publish_to_curseforge(_curseforge_plan(tmp_path), dry_run=False)
    captured = capsys.readouterr()
    assert result is None
    assert "CURSEFORGE_API_TOKEN is not set" in captured.out
    assert "legacy CurseForge webhook token" in captured.out


def test_curseforge_dry_run_does_not_send_token(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv("CURSEFORGE_API_TOKEN", raising=False)
    called = {"urlopen": False}

    def opener(request, timeout=None):
        called["urlopen"] = True
        raise AssertionError("dry-run must not call CurseForge")

    result = publish.publish_to_curseforge(_curseforge_plan(tmp_path), dry_run=True, opener=opener)
    output = capsys.readouterr().out
    assert result == "dry-run"
    assert called["urlopen"] is False
    assert "CurseForge project: 1445757" in output
    assert "Release type: beta" in output
    assert "Retail version: 12.1.0" in output
    assert "Artifact: SpectrumFederation-1.6.0-beta.1.zip" in output
    assert "Changelog source: CHANGELOG.md" in output
    assert "Action: upload" in output
    assert "Authorization: not sent (dry-run)" in output


def test_curseforge_auth_header_and_metadata(tmp_path, monkeypatch):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")
    captured = {}

    def opener(request, timeout=None):
        if request.get_method() == "GET":
            assert request.get_header("X-api-token") == "curse-token-123"
            assert "curse-token-123" not in request.full_url
            assert "token=" not in request.full_url
            return FakeResponse(200, b"[]")
        captured["authorization"] = request.get_header("X-api-token")
        captured["body"] = request.data
        captured["url"] = request.full_url
        return FakeResponse(200, b'{"id": 42}')

    result = publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener)
    assert result == "uploaded"
    assert captured["authorization"] == "curse-token-123"
    assert captured["url"].endswith("/projects/1445757/upload-file")
    assert b"curse-token-123" not in captured["body"]
    metadata = json.loads(captured["body"].split(b"\r\n\r\n", 1)[1].split(b"\r\n")[0])
    assert metadata["releaseType"] == "beta"
    assert metadata["changelog"] == "Beta release 1.6.0-beta.1\n"
    assert metadata["gameVersions"] == [16519]
    assert metadata["gameVersionNames"] == ["12.1.0"]
    assert b'filename="SpectrumFederation-1.6.0-beta.1.zip"' in captured["body"]


@pytest.mark.parametrize(
    ("status", "body", "expected", "message"),
    [
        (401, b'{"message":"unauthorized"}', None, "authentication failed"),
        (403, b'{"message":"forbidden"}', None, "authentication failed"),
        (422, b'{"message":"game version is invalid"}', None, "rejected the release metadata"),
        (404, b'{"message":"project not found"}', None, "was not found or is not authorized"),
        (409, b'{"message":"file already exists"}', "already-exists", "already has this version"),
        (409, b"", None, "without a clear already-exists"),
        (409, b'{"message":"conflict"}', None, "without a clear already-exists"),
        (400, b'{"message":"malformed metadata"}', None, "rejected the release metadata"),
        (500, b'{"message":"server error"}', None, "server error"),
        (418, b'{"message":"teapot"}', None, "unexpected status"),
    ],
)
def test_curseforge_http_responses(tmp_path, monkeypatch, capsys, status, body, expected, message):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")

    def opener(request, timeout=None):
        if request.get_method() == "GET":
            return FakeResponse(200, b"[]")
        raise _http_error(request, status, body)

    result = publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener)
    output = capsys.readouterr().out
    assert result == expected
    assert message in output
    assert "curse-token-123" not in output


def test_curseforge_error_body_redacts_token(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")

    def opener(request, timeout=None):
        if request.get_method() == "GET":
            return FakeResponse(200, b"[]")
        raise _http_error(request, 400, b'{"message":"rejected curse-token-123"}')

    assert publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener) is None
    captured = capsys.readouterr()
    assert "curse-token-123" not in captured.out
    assert "curse-token-123" not in captured.err


def test_curseforge_timeout_and_network_errors(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")

    def timeout_opener(request, timeout=None):
        if request.get_method() == "GET":
            return FakeResponse(200, b"[]")
        raise TimeoutError("timed out")

    assert publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=timeout_opener) is None
    assert "network error" in capsys.readouterr().out

    def network_opener(request, timeout=None):
        if request.get_method() == "GET":
            return FakeResponse(200, b"[]")
        raise urllib_error.URLError("network down")

    assert publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=network_opener) is None
    assert "network error" in capsys.readouterr().out


def test_curseforge_missing_artifact_fails(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")
    plan = _curseforge_plan(tmp_path)
    plan.zip_path.unlink()
    assert publish.publish_to_curseforge(plan) is None
    assert "artifact does not exist" in capsys.readouterr().out


def test_exact_existing_curseforge_file_skips_upload(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")
    methods = []

    def opener(request, timeout=None):
        methods.append(request.get_method())
        assert request.get_method() == "GET"
        body = json.dumps(
            [
                {"fileName": "SpectrumFederation-1.6.0-beta.10.zip", "displayName": "1.6.0-beta.10"},
                {
                    "fileName": "SpectrumFederation-1.6.0-beta.1.zip",
                    "displayName": "1.6.0-beta.1",
                    "releaseType": 2,
                    "gameVersions": [16519],
                    "isAvailable": True,
                    "fileStatus": 10,
                },
            ]
        ).encode()
        return FakeResponse(200, body)

    result = publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener)
    output = capsys.readouterr().out
    assert result == "already-exists"
    assert methods == ["GET"]
    assert "without uploading a duplicate" in output


def test_mismatched_existing_curseforge_file_is_not_success(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")
    methods = []

    def opener(request, timeout=None):
        methods.append(request.get_method())
        body = json.dumps(
            [
                {
                    "fileName": "SpectrumFederation-1.6.0-beta.1.zip",
                    "displayName": "1.6.0-beta.1",
                    "releaseType": "release",
                    "gameVersions": ["12.1.0"],
                    "isAvailable": True,
                    "fileStatus": "approved",
                }
            ]
        ).encode()
        return FakeResponse(200, body)

    result = publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener)
    output = capsys.readouterr().out
    assert result is None
    assert methods == ["GET"]
    assert "does not match this publish" in output
    assert "without uploading a duplicate" not in output


def test_rejected_existing_curseforge_file_is_not_success(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")

    def opener(request, timeout=None):
        body = json.dumps(
            [
                {
                    "fileName": "SpectrumFederation-1.6.0-beta.1.zip",
                    "releaseType": "beta",
                    "gameVersionNames": ["12.1.0"],
                    "isAvailable": False,
                    "fileStatus": 5,
                }
            ]
        ).encode()
        return FakeResponse(200, body)

    assert publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener) is None
    assert "does not match this publish" in capsys.readouterr().out


def _interface_zip(tmp_path, interface):
    zip_path = tmp_path / "SpectrumFederation-1.6.0-beta.1.zip"
    with zipfile.ZipFile(zip_path, "w") as archive:
        archive.writestr(
            "SpectrumFederation/SpectrumFederation.toc",
            f"## Interface: {interface}\n## Version: 1.6.0-beta.1\n",
        )
    return zip_path


def test_curseforge_interface_uses_packaged_toc(tmp_path):
    zip_path = _interface_zip(tmp_path, "120100")
    assert publish.curseforge_interface_from_package("SpectrumFederation", zip_path, 120100) == 120100


def test_curseforge_interface_rejects_requested_mismatch(tmp_path, capsys):
    zip_path = _interface_zip(tmp_path, "120100")
    with pytest.raises(ValueError, match="not requested Interface 120200"):
        publish.curseforge_interface_from_package("SpectrumFederation", zip_path, 120200)
    result = publish.resolve_curseforge_publish_plan(
        version="1.6.0-beta.1",
        classification=publish.classify_release("1.6.0-beta.1"),
        addon_name="SpectrumFederation",
        interface=120200,
        zip_path=zip_path,
        changelog="notes",
        dry_run=True,
    )
    assert result is None
    assert "packaged parent TOC Interface 120100" in capsys.readouterr().out


def test_nearby_curseforge_version_is_not_an_exact_duplicate(tmp_path, monkeypatch):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")
    methods = []

    def opener(request, timeout=None):
        methods.append(request.get_method())
        if request.get_method() == "GET":
            body = json.dumps(
                [{"fileName": "SpectrumFederation-1.6.0-beta.10.zip", "displayName": "1.6.0-beta.10"}]
            ).encode()
            return FakeResponse(200, body)
        return FakeResponse(200, b'{"id": 7}')

    assert publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener) == "uploaded"
    assert methods == ["GET", "POST"]


def test_unavailable_curseforge_file_list_still_uploads(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")

    def opener(request, timeout=None):
        if request.get_method() == "GET":
            raise _http_error(request, 404, b'{"message":"not found"}')
        return FakeResponse(200, b'{"id": 8}')

    result = publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener)
    output = capsys.readouterr().out
    assert result == "uploaded"
    assert "file list is unavailable" in output


def test_curseforge_catalog_is_reused_within_one_invocation(monkeypatch):
    publish.clear_curseforge_catalog_cache()
    calls = []

    def opener(request, timeout=None):
        calls.append(request.full_url)
        if request.full_url.endswith("/game/versions"):
            return FakeResponse(200, json.dumps(_curseforge_versions()).encode())
        if request.full_url.endswith("/game/version-types"):
            return FakeResponse(200, json.dumps(_curseforge_version_types()).encode())
        raise AssertionError(request.full_url)

    first = publish.load_curseforge_catalog("curse-token-123", opener=opener)
    second = publish.load_curseforge_catalog("curse-token-123", opener=opener)
    assert first == second
    assert len(calls) == 2
    publish.clear_curseforge_catalog_cache()


def test_curseforge_failure_still_attempts_wago(tmp_path, monkeypatch, capsys):
    order = []

    def fake_github(*args, **kwargs):
        order.append("github")
        return "created"

    def resolve_curseforge(**kwargs):
        order.append("curseforge-plan")
        return _curseforge_plan(tmp_path)

    def upload_curseforge(plan, **kwargs):
        order.append("curseforge-upload")
        return None

    def resolve_wago(**kwargs):
        order.append("wago-plan")
        return _plan(tmp_path)

    def upload_wago(plan, **kwargs):
        order.append("wago-upload")
        return "uploaded"

    monkeypatch.setattr(publish, "create_github_release", fake_github)
    monkeypatch.setattr(publish, "resolve_curseforge_publish_plan", resolve_curseforge)
    monkeypatch.setattr(publish, "publish_to_curseforge", upload_curseforge)
    monkeypatch.setattr(publish, "resolve_wago_publish_plan", resolve_wago)
    monkeypatch.setattr(publish, "publish_to_wago", upload_wago)

    result = publish.publish_github_then_external(**_orchestrator_args(tmp_path), dry_run=False)
    output = capsys.readouterr().out
    assert result is False
    assert order == ["github", "curseforge-plan", "curseforge-upload", "wago-plan", "wago-upload"]
    assert "CurseForge failed, Wago succeeded" in output
    assert "Do not delete GitHub, CurseForge, or Wago releases" in output


def test_wago_failure_still_attempts_curseforge(tmp_path, monkeypatch, capsys):
    order = []

    def fake_github(*args, **kwargs):
        order.append("github")
        return "created"

    def resolve_curseforge(**kwargs):
        order.append("curseforge-plan")
        return _curseforge_plan(tmp_path)

    def upload_curseforge(plan, **kwargs):
        order.append("curseforge-upload")
        return "already-exists"

    def resolve_wago(**kwargs):
        order.append("wago-plan")
        return _plan(tmp_path)

    def upload_wago(plan, **kwargs):
        order.append("wago-upload")
        return None

    monkeypatch.setattr(publish, "create_github_release", fake_github)
    monkeypatch.setattr(publish, "resolve_curseforge_publish_plan", resolve_curseforge)
    monkeypatch.setattr(publish, "publish_to_curseforge", upload_curseforge)
    monkeypatch.setattr(publish, "resolve_wago_publish_plan", resolve_wago)
    monkeypatch.setattr(publish, "publish_to_wago", upload_wago)

    result = publish.publish_github_then_external(**_orchestrator_args(tmp_path), dry_run=False)
    output = capsys.readouterr().out
    assert result is False
    assert order == ["github", "curseforge-plan", "curseforge-upload", "wago-plan", "wago-upload"]
    assert "CurseForge succeeded, Wago failed" in output


def test_github_failure_skips_curseforge_and_wago(tmp_path, monkeypatch, capsys):
    def fake_github(*args, **kwargs):
        return None

    def fail_external(**kwargs):
        raise AssertionError("downstream publishing must not run")

    monkeypatch.setattr(publish, "create_github_release", fake_github)
    monkeypatch.setattr(publish, "resolve_curseforge_publish_plan", fail_external)
    monkeypatch.setattr(publish, "resolve_wago_publish_plan", fail_external)

    result = publish.publish_github_then_external(**_orchestrator_args(tmp_path), dry_run=False)
    output = capsys.readouterr().out
    assert result is False
    assert "CurseForge and Wago were not attempted" in output


def test_file_list_forbidden_still_uploads(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")
    methods = []

    def opener(request, timeout=None):
        methods.append(request.get_method())
        if request.get_method() == "GET":
            raise _http_error(request, 403, b'{"message":"forbidden"}')
        return FakeResponse(200, b'{"id": 9}')

    result = publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener)
    output = capsys.readouterr().out
    assert result == "uploaded"
    assert methods == ["GET", "POST"]
    assert "file list is unavailable" in output
    assert "authentication failed while checking existing files" not in output


def test_truncated_curseforge_upload_is_a_destination_failure(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CURSEFORGE_API_TOKEN", "curse-token-123")

    class TruncatedResponse(FakeResponse):
        def read(self):
            raise http.client.IncompleteRead(b"partial")

    def opener(request, timeout=None):
        if request.get_method() == "GET":
            return FakeResponse(200, b"[]")
        return TruncatedResponse()

    assert publish.publish_to_curseforge(_curseforge_plan(tmp_path), opener=opener) is None
    assert "CurseForge network error" in capsys.readouterr().out


def test_unexpected_curseforge_error_still_attempts_wago(tmp_path, monkeypatch, capsys):
    order = []

    def fake_github(*args, **kwargs):
        order.append("github")
        return "created"

    def upload_curseforge(plan, **kwargs):
        order.append("curseforge-upload")
        raise RuntimeError("truncated response")

    def resolve_wago(**kwargs):
        order.append("wago-plan")
        return _plan(tmp_path)

    def upload_wago(plan, **kwargs):
        order.append("wago-upload")
        return "uploaded"

    monkeypatch.setattr(publish, "create_github_release", fake_github)
    monkeypatch.setattr(publish, "resolve_curseforge_publish_plan", lambda **kwargs: _curseforge_plan(tmp_path))
    monkeypatch.setattr(publish, "publish_to_curseforge", upload_curseforge)
    monkeypatch.setattr(publish, "resolve_wago_publish_plan", resolve_wago)
    monkeypatch.setattr(publish, "publish_to_wago", upload_wago)

    result = publish.publish_github_then_external(**_orchestrator_args(tmp_path), dry_run=False)
    output = capsys.readouterr().out
    assert result is False
    assert order == ["github", "curseforge-upload", "wago-plan", "wago-upload"]
    assert "CurseForge publication failed unexpectedly" in output
    assert "CurseForge failed, Wago succeeded" in output
