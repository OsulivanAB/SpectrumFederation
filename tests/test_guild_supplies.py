"""Run production Lua Guild Supplies Part 2A/2B/3A/3B/3C tests (#385–#389)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "guild_supplies_tests.lua"
LUA_RENAME_424_TESTS = REPO_ROOT / "tests" / "lua" / "guild_supplies_rename_424_tests.lua"
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


def test_guild_supplies_campaign_rename_424():
    """Focused #424 rename/LWW/adoption coverage (also embedded in the full suite)."""
    assert LUA_RENAME_424_TESTS.exists()
    result = subprocess.run(
        [_lua51(), str(LUA_RENAME_424_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Guild Supplies #424 rename tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert "424-adopt: name adopted" in result.stdout
    assert "424-lww: bob wins equal-time" in result.stdout
    assert "424-rollover: archived name converges" in result.stdout
    assert "424-adopt-lww: early retained in history" in result.stdout
    assert "424-adopt-tie: clear revision kept" in result.stdout


def test_parent_toc_loads_guild_supplies_after_gossip():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    gossip = toc.find("modules/GuildGossip/10_PublicAPI.lua")
    state = toc.find("modules/GuildSupplies/State.lua")
    authority = toc.find("modules/GuildSupplies/Authority.lua")
    operations = toc.find("modules/GuildSupplies/Operations.lua")
    campaigns = toc.find("modules/GuildSupplies/Campaigns.lua")
    activation = toc.find("modules/GuildSupplies/Activation.lua")
    ledger = toc.find("modules/GuildSupplies/Ledger.lua")
    admission = toc.find("modules/GuildSupplies/Admission.lua")
    valuation = toc.find("modules/GuildSupplies/Valuation.lua")
    gs_gossip = toc.find("modules/GuildSupplies/Gossip.lua")
    item_display = toc.find("modules/UI/Settings/ItemDisplay.lua")
    config_page = toc.find("modules/UI/Settings/Pages/GuildSuppliesConfiguration.lua")
    logs_page = toc.find("modules/UI/Settings/Pages/GuildSuppliesLogs.lua")
    troubleshooting_page = toc.find("modules/UI/Settings/Pages/GuildSuppliesTroubleshooting.lua")
    assert 0 <= item_display < config_page < logs_page < troubleshooting_page
    obs = toc.find("modules/LootHelper/ConsumablesObservation.lua")
    assert 0 <= obs
    assert 0 <= gossip < state < authority < operations < campaigns < activation < ledger < admission < valuation < gs_gossip
    assert 0 <= config_page < logs_page < troubleshooting_page


def test_demand_driven_guild_apis_exist():
    text = ADAPTER.read_text(encoding="utf-8")
    assert "function GG.GetGuildIdentity()" in text
    assert "function GG.GetGuildMember(" in text
    assert "function GG.GetGuildRanks()" in text
    assert "demand-driven" in text.lower() or "Demand-driven" in text


def test_provider_registration_only_in_gossip_module():
    """#387: staged config provider lives in Gossip.lua; other GS modules stay transport-free."""
    for path in GS_DIR.glob("*.lua"):
        text = path.read_text(encoding="utf-8")
        assert "EnableSynthetic" not in text
        assert "SendAddonMessage" not in text
        if path.name == "Gossip.lua":
            assert "RegisterProvider" in text or "GG.RegisterProvider" in text or ":Register(" in text
            assert "sf.guildsupplies.config" in text
        else:
            assert "RegisterProvider" not in text
