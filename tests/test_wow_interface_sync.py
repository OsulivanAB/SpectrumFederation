from __future__ import annotations

import importlib.util
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

    assert wow.parse_live_version_from_text(blizztrack_html, source_name="BlizzTrack") == "12.0.1.63091"
    assert wow.parse_live_version_from_text(blizzmeta_html, source_name="BlizzMeta") == "12.0.1.63091"


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


def test_manual_override_is_used_after_network_failures(monkeypatch):
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


def test_compute_updated_versions_preserves_beta_offset():
    main_version = wow.parse_version("0.5.10")
    beta_version = wow.parse_version("0.5.10-beta.2")

    new_main, new_beta, beta_ahead = wow.compute_updated_versions(main_version, beta_version, main_update_needed=True)

    assert new_main.raw == "0.5.11"
    assert new_beta.raw == "0.5.11-beta.2"
    assert beta_ahead is False


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
