"""Run production Lua guild officer-rank tests (#405)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "guild_officer_tests.lua"
POLICY = REPO_ROOT / "SpectrumFederation" / "modules" / "GuildOfficer" / "Policy.lua"
DOCS = REPO_ROOT / "docs" / "development" / "guild-officer.md"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production guild officer tests")


def test_guild_officer_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 guild officer tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert POLICY.exists()
    assert DOCS.exists()


def test_parent_toc_loads_guild_officer_before_consumers():
    toc = (REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc").read_text(encoding="utf-8")
    policy = toc.find("modules/GuildOfficer/Policy.lua")
    gossip = toc.find("modules/GuildOfficer/Gossip.lua")
    supplies = toc.find("modules/GuildSupplies/State.lua")
    info = toc.find("modules/GuildInfo/Authority.lua")
    assert 0 <= policy < gossip < supplies < info
    text = POLICY.read_text(encoding="utf-8")
    assert 'PROVIDER_ID = "sf.guildofficer.policy"' in text
    assert "SendAddonMessage" not in text
