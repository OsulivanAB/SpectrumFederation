"""Run production Lua linked-character identity tests for issue #276."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
IDENTITY_MODULE = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Identity.lua"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "linked_identity_tests.lua"
BENCHMARK_TESTS = REPO_ROOT / "tests" / "lua" / "identity_replay_benchmark_tests.lua"
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production linked-identity tests")


def test_linked_identity_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 linked-identity tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert IDENTITY_MODULE.exists()


def test_identity_replay_benchmark_production_lua():
    result = subprocess.run(
        [_lua51(), str(BENCHMARK_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 identity replay benchmark failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert "F-02 identity replay benchmark" in result.stdout


def test_identity_module_is_packaged():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    assert "modules/LootHelper/Identity.lua" in toc
    assert toc.find("modules/LootHelper/LootLogs.lua") < toc.find("modules/LootHelper/Identity.lua")
    assert toc.find("modules/LootHelper/Identity.lua") < toc.find("modules/LootHelper/Profiles.lua")
