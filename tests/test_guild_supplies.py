"""Run production Lua Guild Supplies Part 2A tests (#385)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "guild_supplies_tests.lua"
GS_DIR = REPO_ROOT / "SpectrumFederation" / "modules" / "GuildSupplies"
DOCS = REPO_ROOT / "docs" / "development" / "guild-supplies" / "index.md"
ADAPTER = REPO_ROOT / "SpectrumFederation" / "modules" / "GuildGossip" / "05_GuildAdapter.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Guild Supplies tests")


def test_guild_supplies_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Guild Supplies tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert GS_DIR.exists()
    assert DOCS.exists()


def test_parent_toc_loads_guild_supplies_after_gossip():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    gossip = toc.find("modules/GuildGossip/10_PublicAPI.lua")
    state = toc.find("modules/GuildSupplies/State.lua")
    authority = toc.find("modules/GuildSupplies/Authority.lua")
    operations = toc.find("modules/GuildSupplies/Operations.lua")
    assert 0 <= gossip < state < authority < operations


def test_demand_driven_guild_apis_exist():
    text = ADAPTER.read_text(encoding="utf-8")
    assert "function GG.GetGuildIdentity()" in text
    assert "function GG.GetGuildMember(" in text
    assert "function GG.GetGuildRanks()" in text
    assert "demand-driven" in text.lower() or "Demand-driven" in text


def test_no_provider_registration_in_guild_supplies():
    for path in GS_DIR.glob("*.lua"):
        text = path.read_text(encoding="utf-8")
        assert "RegisterProvider" not in text
        assert "EnableSynthetic" not in text
        assert "SendAddonMessage" not in text
