"""Run production Lua tests for the read-only TradeSkillMaster adapter."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "tsm_integration_tests.lua"
ADAPTER = REPO_ROOT / "SpectrumFederation" / "modules" / "Integrations" / "TSM.lua"
ADDON_ROOTS = (
    REPO_ROOT / "SpectrumFederation",
    REPO_ROOT / "SpectrumFederation_CursedSurgeTracker",
    REPO_ROOT / "SpectrumFederation_RCLootCouncilIntegration",
)


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production TSM adapter tests")


def test_tsm_adapter_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 TSM adapter tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert ADAPTER.exists()


def test_parent_toc_loads_tsm_adapter_after_debug():
    parent = PARENT_TOC.read_text(encoding="utf-8")
    debug = parent.find("modules/debug.lua")
    adapter = parent.find("modules/Integrations/TSM.lua")
    assert debug >= 0
    assert adapter > debug


def test_tsm_adapter_stays_read_only_and_idle():
    text = ADAPTER.read_text(encoding="utf-8")
    for forbidden in (
        "TradeSkillMasterDB",
        "OnUpdate",
        "C_Timer",
        "CreateFrame",
        "RegisterEvent",
        "SavedVariables",
    ):
        assert forbidden not in text


def test_feature_modules_do_not_call_tsm_api_directly():
    """Feature modules may call SF.TSM. Only the adapter may call TSM_API."""
    for root in ADDON_ROOTS:
        for path in root.rglob("*.lua"):
            if path.resolve() == ADAPTER.resolve():
                continue
            text = path.read_text(encoding="utf-8")
            assert "TSM_API" not in text
