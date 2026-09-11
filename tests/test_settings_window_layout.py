"""Run production Lua Settings window layout tests."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "settings_window_layout_tests.lua"
SECTION_LAYOUT_TESTS = REPO_ROOT / "tests" / "lua" / "settings_section_layout_tests.lua"
WINDOW = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "StandaloneWindow.lua"
SECTION = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "Widgets" / "Section.lua"
PAGE_BUILDER = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "PageBuilder.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Settings window layout tests")


def test_settings_window_layout_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Settings window layout tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert WINDOW.exists()


def test_settings_section_fill_height_layout_production_lua():
    result = subprocess.run(
        [_lua51(), str(SECTION_LAYOUT_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Settings section fill-height layout tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert SECTION.exists()
    assert PAGE_BUILDER.exists()
