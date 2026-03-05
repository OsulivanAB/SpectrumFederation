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
    payload = "\n".join(
        [
            "eu|wow|something|something|something|11.2.5.63906|cdn|buildcfg",
            "us|wow|something|something|something|12.0.1.63091|cdn|buildcfg",
        ]
    )

    version = wow.parse_version_response(payload, region="us")
    interface = wow.version_to_interface(version)

    assert version == "12.0.1.63091"
    assert interface == 120001


def test_parse_wowhead_interface_from_html():
    html = """
    <section>
      <h3>World of Warcraft Live Interface</h3>
      <p>Current live interface: 120001</p>
    </section>
    """
    assert wow.parse_wowhead_interface_response(html) == 120001


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


def test_override_env_var_wins(monkeypatch):
    monkeypatch.setenv("LIVE_INTERFACE_OVERRIDE", "120001")
    monkeypatch.setattr(
        wow,
        "_resolve_patch_server",
        lambda _region: pytest.fail("patch server strategy should not run when override is set"),
    )
    monkeypatch.setattr(
        wow,
        "_resolve_wowhead",
        lambda: pytest.fail("wowhead strategy should not run when override is set"),
    )

    version, interface = wow.resolve_live_interface("us")
    assert version is None
    assert interface == 120001
