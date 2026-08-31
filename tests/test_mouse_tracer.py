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
SCHEMA = REPO_ROOT / "SpectrumFederation" / "modules" / "Settings" / "Schema.lua"
NICHE_FEATURES = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "Pages" / "NicheFeatures.lua"


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


def test_schema_and_slider_match_new_mouse_tracer_defaults():
    schema = SCHEMA.read_text(encoding="utf-8")
    page = NICHE_FEATURES.read_text(encoding="utf-8")
    constants = CONSTANTS.read_text(encoding="utf-8")
    assert "enabled = false" in schema
    assert "trailLength = 400" in schema
    assert "fadeDuration = 0.50" in schema
    assert "thickness = 16" in schema
    assert "rainbowSpeed = 0.25" in schema
    assert "opacity = 0.70" in schema
    assert "DEFAULT_TRAIL_LENGTH = 400" in constants
    assert "DEFAULT_FADE_DURATION = 0.50" in constants
    assert "DEFAULT_THICKNESS = 16" in constants
    assert "DEFAULT_RAINBOW_SPEED = 0.25" in constants
    assert "DEFAULT_OPACITY = 0.70" in constants
    assert "MAX_TRAIL_LENGTH = 1200" in constants
    assert "TAPER_MIN_RATIO = 0.40" in constants
    assert "max = 1200" in page
    assert "label = \"Trail Length\"" in page
