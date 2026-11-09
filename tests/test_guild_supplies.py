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
LUA_UI_453_TESTS = REPO_ROOT / "tests" / "lua" / "guild_supplies_453_tests.lua"
LUA_457_TESTS = REPO_ROOT / "tests" / "lua" / "guild_supplies_457_tests.lua"
LUA_CORRECTION_459_TESTS = REPO_ROOT / "tests" / "lua" / "guild_supplies_459_tests.lua"
LUA_SOFT_DELETE_465_TESTS = REPO_ROOT / "tests" / "lua" / "guild_supplies_465_tests.lua"
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


def test_guild_supplies_raid_supply_ui_453():
    """Focused #453 Configuration/Manage/Logs presentation coverage."""
    assert LUA_UI_453_TESTS.exists()
    result = subprocess.run(
        [_lua51(), str(LUA_UI_453_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Guild Supplies #453 UI tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert "453: Initialize on first-time setup" in result.stdout
    assert "453: Activate hidden after activation" in result.stdout
    assert "453: Manage hosts gsItems" in result.stdout
    assert "453: Preview as Non-Admin hides Manage" in result.stdout
    assert "453: dropdown appends (Current)" in result.stdout
    assert "453: unassigned adjustment contributor" in result.stdout
    assert "453: all retained entries projected (>25)" in result.stdout
    assert "453: combined filters cover removed-item donations" in result.stdout


def test_guild_supplies_quick_withdraw_457():
    """Focused #457 recipe arithmetic, receipts, and trade-batch coverage."""
    assert LUA_457_TESTS.exists()
    result = subprocess.run(
        [_lua51(), str(LUA_457_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Guild Supplies #457 Quick Withdraw tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "guild_supplies_457_tests: ok" in result.stdout


def test_guild_supplies_contributor_corrections_459():
    """Focused #459 officer contributor correction admission/projection coverage."""
    assert LUA_CORRECTION_459_TESTS.exists()
    result = subprocess.run(
        [_lua51(), str(LUA_CORRECTION_459_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Guild Supplies #459 correction tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert "459: PROVIDER_SCHEMA is 7" in result.stdout
    assert "459: effective credit is Bob" in result.stdout
    assert "459: floor reason player_negative" in result.stdout
    assert "459: LWW effective Carol" in result.stdout
    assert "459: credit after redrive" in result.stdout
    assert "459: preview reason got preview_non_admin" in result.stdout


def test_guild_supplies_soft_delete_465():
    """Focused #465 officer soft-delete admission/projection coverage."""
    assert LUA_SOFT_DELETE_465_TESTS.exists()
    result = subprocess.run(
        [_lua51(), str(LUA_SOFT_DELETE_465_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Guild Supplies #465 soft-delete tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert "465: PROVIDER_SCHEMA is 7" in result.stdout
    assert "465: delete succeeds with debt" in result.stdout
    assert "465: signed personal debt −8" in result.stdout
    assert "465: explicit repair restores zero" in result.stdout
    assert "465: personal restored to 10" in result.stdout
    assert "465: pending delete promoted after event" in result.stdout
    assert "465: preview reason got preview_non_admin" in result.stdout
    assert "465-xevt: A debt −10" in result.stdout
    assert "465-xevt2: debt survives reload" in result.stdout
    assert "465-xevt-repair: zero after explicit adjustment" in result.stdout
    assert "465-alias: reobservation alias stays deleted" in result.stdout
    assert "465-adopt-del: commit got accepted/nil" in result.stdout
    assert "465-adopt-corr: credit not reinstated" in result.stdout
    assert "465-surv: Bob keeps corrected credit" in result.stdout
    assert "465-surv: Bob unchanged after Alice repair" in result.stdout
    assert "465-ex: SF.Debug:Error recorded admit failure" in result.stdout
    assert "465-ex: idle after successful drain" in result.stdout

def test_parent_toc_loads_guild_supplies_after_gossip():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    gossip = toc.find("modules/GuildGossip/10_PublicAPI.lua")
    state = toc.find("modules/GuildSupplies/State.lua")
    authority = toc.find("modules/GuildSupplies/Authority.lua")
    recipes = toc.find("modules/GuildSupplies/Recipes.lua")
    operations = toc.find("modules/GuildSupplies/Operations.lua")
    campaigns = toc.find("modules/GuildSupplies/Campaigns.lua")
    activation = toc.find("modules/GuildSupplies/Activation.lua")
    ledger = toc.find("modules/GuildSupplies/Ledger.lua")
    withdrawals = toc.find("modules/GuildSupplies/Withdrawals.lua")
    admission = toc.find("modules/GuildSupplies/Admission.lua")
    valuation = toc.find("modules/GuildSupplies/Valuation.lua")
    gs_gossip = toc.find("modules/GuildSupplies/Gossip.lua")
    item_display = toc.find("modules/UI/Settings/ItemDisplay.lua")
    config_page = toc.find("modules/UI/Settings/Pages/GuildSuppliesConfiguration.lua")
    manage_page = toc.find("modules/UI/Settings/Pages/GuildSuppliesManage.lua")
    logs_page = toc.find("modules/UI/Settings/Pages/GuildSuppliesLogs.lua")
    rankings_page = toc.find("modules/UI/Settings/Pages/GuildSuppliesRankings.lua")
    troubleshooting_page = toc.find("modules/UI/Settings/Pages/GuildSuppliesTroubleshooting.lua")
    withdraw_workflow = toc.find("modules/LootHelper/ConsumablesWithdrawWorkflow.lua")
    withdraw_runtime = toc.find("modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    trade_handoff = toc.find("modules/LootHelper/ConsumablesTradeHandoff.lua")
    consumables_runtime = toc.find("modules/LootHelper/ConsumablesRuntime.lua")
    assert 0 <= item_display < config_page < manage_page < logs_page < rankings_page < troubleshooting_page
    obs = toc.find("modules/LootHelper/ConsumablesObservation.lua")
    assert 0 <= obs
    assert 0 <= gossip < state < authority < recipes < operations < campaigns < activation < ledger < withdrawals < admission < valuation < gs_gossip
    assert 0 <= config_page < manage_page < logs_page < rankings_page < troubleshooting_page
    assert 0 <= withdraw_workflow < withdraw_runtime < trade_handoff < consumables_runtime


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
