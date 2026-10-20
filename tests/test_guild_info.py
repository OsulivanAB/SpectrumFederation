"""Run production Lua Guild Info main/alt tests (#402)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "guild_info_tests.lua"
GI_DIR = REPO_ROOT / "SpectrumFederation" / "modules" / "GuildInfo"
DOCS = REPO_ROOT / "docs" / "development" / "guild-info" / "index.md"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Guild Info tests")


def test_guild_info_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Guild Info tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert GI_DIR.exists()
    assert DOCS.exists()


def test_parent_toc_loads_guild_info_after_guild_supplies():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    gs_gossip = toc.find("modules/GuildSupplies/Gossip.lua")
    state = toc.find("modules/GuildInfo/State.lua")
    authority = toc.find("modules/GuildInfo/Authority.lua")
    operations = toc.find("modules/GuildInfo/Operations.lua")
    roster = toc.find("modules/GuildInfo/Roster.lua")
    gi_gossip = toc.find("modules/GuildInfo/Gossip.lua")
    page = toc.find("modules/UI/Settings/Pages/MainAltAssignments.lua")
    assert 0 <= gs_gossip < state < authority < operations < roster < gi_gossip
    assert 0 <= page


def test_guild_info_provider_id_isolated():
    gossip = (GI_DIR / "Gossip.lua").read_text(encoding="utf-8")
    state = (GI_DIR / "State.lua").read_text(encoding="utf-8")
    assert "sf.guildinfo.relationships" in state or "sf.guildinfo.relationships" in gossip
    assert "sf.guildsupplies.config" not in gossip
    for path in GI_DIR.glob("*.lua"):
        text = path.read_text(encoding="utf-8")
        assert "SendAddonMessage" not in text
        assert "EnableSynthetic" not in text


def test_guild_info_state_based_schema_markers():
    state = (GI_DIR / "State.lua").read_text(encoding="utf-8")
    gossip = (GI_DIR / "Gossip.lua").read_text(encoding="utf-8")
    docs = DOCS.read_text(encoding="utf-8")
    assert "SCHEMA_VERSION = 3" in state
    assert "PROVIDER_SCHEMA = 3" in state or "PROVIDER_SCHEMA = 3" in gossip
    assert "guildinfo-member" in gossip
    assert "guildinfo-group" in gossip
    assert "guildinfo-epoch" in gossip
    assert "MAX_MEMBERS = 256" in state
    assert "MAX_GROUPS = 128" in state
    assert "schemaVersion = 3" in docs
    assert "syncGen" in state or "sync generation" in docs.lower()
    assert "versioned" in docs.lower()
    assert "operation log" in docs.lower() or "op-log" in docs.lower() or "append-only" in docs.lower()
    assert "guildinfo-op" not in gossip
    cleanup = (GI_DIR / "Cleanup.lua").read_text(encoding="utf-8")
    assert "ApplyCleanupHistory" in cleanup
    assert "AdoptSyncGeneration" in cleanup


def test_guild_info_does_not_touch_supplies_or_loot_helper_identity():
    for path in GI_DIR.glob("*.lua"):
        text = path.read_text(encoding="utf-8")
        assert "identityLinks" not in text
        assert "AreSameWitnessIdentity" not in text
        assert "LootHelper/Identity" not in text
        assert "SF.GuildSupplies" not in text
