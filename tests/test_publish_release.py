"""Tests for GitHub/Wago release classification and Wago publishing."""

from __future__ import annotations

import importlib.util
import io
import json
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
    ("version", "stability", "is_prerelease", "github_kind"),
    [
        ("1.4.0", "stable", False, "release"),
        ("1.5.0-beta.1", "beta", True, "prerelease"),
        ("1.5.0-BETA.2", "beta", True, "prerelease"),
        ("1.5.0-alpha.1", "alpha", True, "prerelease"),
        ("1.5.0-rc.1", "beta", True, "prerelease"),
    ],
)
def test_classify_release_maps_version_to_github_and_wago(version, stability, is_prerelease, github_kind):
    classification = publish.classify_release(version)
    assert classification.wago_stability == stability
    assert classification.is_prerelease is is_prerelease
    assert classification.github_release_kind == github_kind


def test_classify_release_does_not_treat_alphabet_as_alpha():
    classification = publish.classify_release("1.5.0-alphabet.1")
    assert classification.wago_stability == "stable"
    assert classification.is_prerelease is False


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
        "Bearer developer-key-123"
    )
    sanitized = publish.sanitize_output(leaked)
    assert "developer-key-123" not in sanitized
    assert "legacy-webhook-secret" not in sanitized
    assert "Bearer ***" in sanitized
    assert "WAGO_API_KEY=" in sanitized


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


def test_validate_packaging_accepts_parent_wago_id(tmp_path):
    parent_toc = tmp_path / "parent.toc"
    child_toc = tmp_path / "child.toc"
    parent_toc.write_text("## X-Wago-ID: BNBmnlGx\n", encoding="utf-8")
    child_toc.write_text("## Version: 1.4.0\n", encoding="utf-8")
    assert validate_packaging.validate_wago_project_id(parent_toc, child_toc) is True


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


def test_live_github_runs_before_wago_catalog_lookup(tmp_path, monkeypatch, capsys):
    addon = tmp_path / "SpectrumFederation"
    addon.mkdir()
    (addon / "SpectrumFederation.toc").write_text(
        "## X-Wago-ID: BNBmnlGx\n",
        encoding="utf-8",
    )
    monkeypatch.chdir(tmp_path)
    order = []

    def fake_github(*args, **kwargs):
        order.append("github")
        return "created"

    def fake_catalog():
        order.append("wago-catalog")
        return None

    def fail_upload(*args, **kwargs):
        raise AssertionError("Wago upload must not run")

    monkeypatch.setattr(publish, "create_github_release", fake_github)
    monkeypatch.setattr(publish, "fetch_wago_game_data", fake_catalog)
    monkeypatch.setattr(publish, "publish_to_wago", fail_upload)

    result = publish.publish_github_then_wago(**_orchestrator_args(tmp_path), dry_run=False)
    captured = capsys.readouterr()
    assert result is False
    assert order == ["github", "wago-catalog"]
    assert "GitHub release succeeded, but Wago publication failed" in captured.out
    assert "Do not roll back CurseForge" in captured.out


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

    monkeypatch.setattr(publish, "create_github_release", fake_github)
    monkeypatch.setattr(publish, "resolve_wago_publish_plan", fail_plan)
    monkeypatch.setattr(publish, "publish_to_wago", fail_upload)

    result = publish.publish_github_then_wago(**_orchestrator_args(tmp_path), dry_run=False)
    captured = capsys.readouterr()
    assert result is False
    assert github_calls == [False]
    assert "GitHub release action: updated" in captured.out
    assert "GitHub release succeeded, but Wago publication failed" in captured.out


def test_dry_run_validates_wago_before_simulated_github(tmp_path, monkeypatch, capsys):
    order = []

    def fail_plan(**kwargs):
        order.append("wago-plan")
        return None

    def fake_github(*args, **kwargs):
        order.append("github")
        return "dry-run"

    monkeypatch.setattr(publish, "resolve_wago_publish_plan", fail_plan)
    monkeypatch.setattr(publish, "create_github_release", fake_github)

    result = publish.publish_github_then_wago(**_orchestrator_args(tmp_path), dry_run=True)
    captured = capsys.readouterr()
    assert result is False
    assert order == ["wago-plan"]
    assert "GitHub release succeeded, but Wago publication failed" not in captured.out
