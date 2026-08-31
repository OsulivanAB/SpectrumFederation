"""Run production Lua Mouse Tracer tests and related TOC metadata checks."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "mouse_tracer_tests.lua"
CONSTANTS = REPO_ROOT / "SpectrumFederation" / "modules" / "MouseTracer" / "Constants.lua"
ENGINE = REPO_ROOT / "SpectrumFederation" / "modules" / "MouseTracer" / "TrailEngine.lua"
RUNTIME = REPO_ROOT / "SpectrumFederation" / "modules" / "MouseTracer" / "MouseTracer.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Mouse Tracer tests")


def test_mouse_tracer_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Mouse Tracer tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert CONSTANTS.exists()
    assert ENGINE.exists()
    assert RUNTIME.exists()


def test_parent_toc_loads_mouse_tracer_modules():
    parent = PARENT_TOC.read_text(encoding="utf-8")
    assert "modules/MouseTracer/Constants.lua" in parent
    assert "modules/MouseTracer/TrailEngine.lua" in parent
    assert "modules/MouseTracer/MouseTracer.lua" in parent
