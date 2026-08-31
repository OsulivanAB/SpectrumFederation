"""Run production Lua navigation tests and related TOC metadata checks."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
CHILD_TOC = (
    REPO_ROOT
    / "SpectrumFederation_CursedSurgeTracker"
    / "SpectrumFederation_CursedSurgeTracker.toc"
)
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "settings_navigation_tests.lua"
NAV_MODEL = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "NavigationModel.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production NavigationModel tests")


def test_settings_navigation_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 navigation tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert NAV_MODEL.exists()


def test_child_toc_declares_parent_metadata_key():
    child = CHILD_TOC.read_text(encoding="utf-8")
    parent = PARENT_TOC.read_text(encoding="utf-8")
    assert "## X-SpectrumFederation-Parent: SpectrumFederation" in child
    assert "## Group: SpectrumFederation" in child
    assert "## Dependencies: SpectrumFederation" in child
    assert "SpectrumFederation_CursedSurgeTracker" not in parent
    assert "CursedSurgeTracker" not in parent
    assert "modules/UI/Settings/NavigationModel.lua" in parent
    assert "modules/UI/Settings/SubAddons.lua" in parent
    assert "modules/UI/Settings/Widgets/TabBar.lua" in parent
    assert "modules/UI/Settings/Widgets/EmptyState.lua" in parent
