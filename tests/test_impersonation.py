"""Run production Lua impersonation tests under lua5.1."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "impersonation_tests.lua"
IMP_MODULE = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Impersonation.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production impersonation tests")


def test_impersonation_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 impersonation tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert IMP_MODULE.exists()


def test_impersonation_is_packaged_in_parent_toc():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    assert "modules/LootHelper/Impersonation.lua" in toc
    loot_helper = toc.find("modules/LootHelper/LootHelper.lua")
    impersonation = toc.find("modules/LootHelper/Impersonation.lua")
    sync_ns = toc.find("modules/LootHelperSync/00_Namespace.lua")
    assert 0 <= loot_helper < impersonation < sync_ns
