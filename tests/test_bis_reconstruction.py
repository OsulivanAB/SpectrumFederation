"""Run production Lua BiS reconstruction tests for issue #275."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BIS_MODULE = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Bis.lua"
SPEC_MODULE = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "SpecWeapons.lua"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "bis_reconstruction_tests.lua"
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production BiS reconstruction tests")


def test_bis_reconstruction_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 BiS reconstruction tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert BIS_MODULE.exists()
    assert SPEC_MODULE.exists()


def test_bis_modules_are_packaged():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    assert "modules/LootHelper/SpecWeapons.lua" in toc
    assert "modules/LootHelper/Bis.lua" in toc
    assert toc.find("modules/LootHelper/Identity.lua") < toc.find("modules/LootHelper/SpecWeapons.lua")
    assert toc.find("modules/LootHelper/SpecWeapons.lua") < toc.find("modules/LootHelper/Bis.lua")
    assert toc.find("modules/LootHelper/Bis.lua") < toc.find("modules/LootHelper/Profiles.lua")
