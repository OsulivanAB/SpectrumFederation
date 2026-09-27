"""Run production Lua Loot Logs presentation tests for issue #317."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PAGE = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "Pages" / "LootLogs.lua"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "loot_logs_view_tests.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Loot Logs view tests")


def test_loot_logs_view_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Loot Logs view tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert PAGE.exists()
