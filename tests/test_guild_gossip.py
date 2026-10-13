"""Run production Lua Guild Gossip Phase 1 tests (#378)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "guild_gossip_tests.lua"
GOSSIP_DIR = REPO_ROOT / "SpectrumFederation" / "modules" / "GuildGossip"
COMM = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Comm.lua"
DOCS = REPO_ROOT / "docs" / "development" / "guild-gossip" / "index.md"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Guild Gossip tests")


def test_guild_gossip_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Guild Gossip tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert GOSSIP_DIR.exists()
    assert DOCS.exists()


def test_parent_toc_loads_guild_gossip_after_comm():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    comm = toc.find("modules/LootHelper/Comm.lua")
    gossip = toc.find("modules/GuildGossip/01_Constants.lua")
    public = toc.find("modules/GuildGossip/10_PublicAPI.lua")
    assert 0 <= comm < gossip < public
    assert COMM.exists()
    assert "SF_GG" in (GOSSIP_DIR / "01_Constants.lua").read_text(encoding="utf-8")


def test_comm_registers_gossip_prefix():
    text = COMM.read_text(encoding="utf-8")
    assert 'GOSSIP  = "SF_GG"' in text or 'GOSSIP = "SF_GG"' in text
    assert "RegisterGossipHandler" in text
    assert "BACKGROUND" in text
    assert "InstallReceiveGuard" in text
