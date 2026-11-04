"""Run production Lua Mouse Tracer tests and related TOC metadata checks."""

from __future__ import annotations

import math
import shutil
import struct
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
LOCALE = REPO_ROOT / "SpectrumFederation" / "locale" / "enUS.lua"
SOFT_MEDIA = REPO_ROOT / "SpectrumFederation" / "media" / "MouseTracer"
SOFT_GENERATOR = REPO_ROOT / "tools" / "generate_mouse_tracer_soft_circles.py"


def _load_tga_alpha(path: Path) -> tuple[int, int, list[list[int]]]:
    data = path.read_bytes()
    assert len(data) > 18, f"{path.name} is smaller than a TGA header"
    id_len = data[0]
    image_type = data[2]
    width, height = struct.unpack_from("<HH", data, 12)
    bpp = data[16]
    desc = data[17]
    assert image_type == 2, f"{path.name} must be uncompressed true-color TGA"
    assert width == 64 and height == 64, f"{path.name} must be 64x64"
    assert bpp == 32, f"{path.name} must be 32-bit BGRA"
    assert (desc & 0x0F) == 8, f"{path.name} must declare 8-bit alpha"
    start = 18 + id_len
    rows: list[list[int]] = []
    for y in range(height):
        src_y = y if (desc & 0x20) else (height - 1 - y)
        row: list[int] = []
        for x in range(width):
            off = start + (src_y * width + x) * 4
            _b, _g, r, a = data[off : off + 4]
            assert r == 255, f"{path.name} RGB must stay white"
            row.append(a)
        rows.append(row)
    return width, height, rows


def _radial_means(alpha: list[list[int]]) -> list[float]:
    height = len(alpha)
    width = len(alpha[0])
    cx = (width - 1) / 2.0
    cy = (height - 1) / 2.0
    buckets: dict[int, list[int]] = {}
    for y, row in enumerate(alpha):
        for x, value in enumerate(row):
            radius = int(math.hypot(x - cx, y - cy))
            buckets.setdefault(radius, []).append(value)
    return [sum(buckets[r]) / len(buckets[r]) for r in sorted(buckets)]


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
    locale = LOCALE.read_text(encoding="utf-8")
    assert "enabled = false" in schema
    assert "trailLength = 400" in schema
    assert "fadeDuration = 0.50" in schema
    assert "thickness = 16" in schema
    assert "rainbowSpeed = 0.25" in schema
    assert "opacity = 0.70" in schema
    assert "edgeSoftness = 0" in schema
    assert "DEFAULT_TRAIL_LENGTH = 400" in constants
    assert "DEFAULT_FADE_DURATION = 0.50" in constants
    assert "DEFAULT_THICKNESS = 16" in constants
    assert "DEFAULT_RAINBOW_SPEED = 0.25" in constants
    assert "DEFAULT_OPACITY = 0.70" in constants
    assert "DEFAULT_EDGE_SOFTNESS = 0" in constants
    assert "MAX_EDGE_SOFTNESS = 100" in constants
    assert "EDGE_SOFTNESS_STEP = 10" in constants
    assert "MAX_TRAIL_LENGTH = 1200" in constants
    assert "TAPER_MIN_RATIO = 0.40" in constants
    assert "SoftCircle_%d.tga" in constants
    assert "FULL_RECT_MASK" in constants
    assert "WHITE8X8" in constants
    assert "StampAppearanceForEdgeSoftness" in ENGINE.read_text(encoding="utf-8")
    assert "RefreshLiveStampAppearances" in RUNTIME.read_text(encoding="utf-8")
    runtime = RUNTIME.read_text(encoding="utf-8")
    assert "RunEdgeSoftnessDiagnostic" in runtime
    assert "stampAppliedTexture[idx] ~= texture" in runtime
    assert "stampAppliedMask[idx] ~= mask" in runtime
    assert "stampAppliedBlend[idx] ~= blend" in runtime
    assert "max = 1200" in page
    assert "label = \"Trail Length\"" in page
    assert "mouseTracer.edgeSoftness" in page
    assert "MOUSE_TRACER_EDGE_SOFTNESS_LABEL" in page
    assert 'L["MOUSE_TRACER_EDGE_SOFTNESS_LABEL"]' in locale
    assert 'L["MOUSE_TRACER_EDGE_SOFTNESS_TOOLTIP"]' in locale
    assert 'L["MOUSE_TRACER_SOFTNESS_DIAG_TITLE"]' in locale
    assert 'L["MOUSE_TRACER_SOFTNESS_DIAG_BLEND_NONE"]' in locale
    assert 'L["MOUSE_TRACER_SOFTNESS_DIAG_ADD_NONE"]' in locale
    assert 'L["MOUSE_TRACER_SOFTNESS_DIAG_ADD_CIRCLE"]' in locale
    assert 'L["MOUSE_TRACER_SOFTNESS_DIAG_OVERLAP_BLEND_NONE"]' in locale
    # Checked-in SoftCircle assets are authoritative; do not ship an inaccurate generator.
    assert not SOFT_GENERATOR.exists(), "inaccurate soft-circle generator must not remain checked in"


def test_soft_circle_assets_have_progressive_alpha_feather():
    previous_mid = None
    previous_unique = None
    for pct in range(10, 101, 10):
        asset = SOFT_MEDIA / f"SoftCircle_{pct}.tga"
        assert asset.is_file(), f"missing soft circle asset for {pct}%"
        width, height, alpha = _load_tga_alpha(asset)
        assert width == 64 and height == 64
        center = alpha[height // 2][width // 2]
        corners = (
            alpha[0][0],
            alpha[0][width - 1],
            alpha[height - 1][0],
            alpha[height - 1][width - 1],
        )
        assert center == 255, f"{asset.name} center must be opaque"
        assert corners == (0, 0, 0, 0), f"{asset.name} exterior must be transparent"

        means = _radial_means(alpha)
        # Alpha must never rise as radius increases (monotone radial fade).
        for inner, outer in zip(means, means[1:]):
            assert outer <= inner + 1e-9, f"{asset.name} alpha rises with radius"

        unique = len({value for row in alpha for value in row})
        assert unique >= 40, f"{asset.name} should carry a multi-level feather ({unique} levels)"

        # Mid-radius mean must fall as softness increases (progression).
        mid_index = max(1, int(len(means) * 0.55))
        mid = means[min(mid_index, len(means) - 1)]
        if previous_mid is not None:
            assert mid <= previous_mid + 1e-9, (
                f"{asset.name} mid-radius alpha must not exceed the previous softness step"
            )
        previous_mid = mid
        if previous_unique is not None and pct >= 50:
            # Higher softness keeps a rich gradient; do not collapse to a hard disk.
            assert unique >= 80, f"{asset.name} high-softness gradient is too coarse ({unique})"
        previous_unique = unique

    hardest = _load_tga_alpha(SOFT_MEDIA / "SoftCircle_10.tga")[2]
    softest = _load_tga_alpha(SOFT_MEDIA / "SoftCircle_100.tga")[2]
    hard_unique = len({value for row in hardest for value in row})
    soft_unique = len({value for row in softest for value in row})
    assert soft_unique > hard_unique, "100% softness must expose more alpha levels than 10%"
