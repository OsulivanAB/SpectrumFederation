"""Run production Lua Loot Helper window minimize-anchor tests."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "loot_helper_window_tests.lua"
WINDOW = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "LootHelper" / "Window.lua"
CONSTANTS = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "LootHelper" / "Constants.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Loot Helper window tests")


def test_loot_helper_window_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Loot Helper window tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert WINDOW.exists()
    assert CONSTANTS.exists()
