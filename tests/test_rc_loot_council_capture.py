"""Run production Lua RC Loot Council capture tests and child-addon TOC checks."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
CHILD_ROOT = REPO_ROOT / "SpectrumFederation_RCLootCouncilCapture"
CHILD_TOC = CHILD_ROOT / "SpectrumFederation_RCLootCouncilCapture.toc"
CAPTURE_LUA = CHILD_ROOT / "Capture.lua"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "rc_loot_council_capture_tests.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production RC capture tests")


def _toc_field(toc: Path, field_name: str) -> str:
    for line in toc.read_text(encoding="utf-8").splitlines():
        prefix = f"## {field_name}:"
        if line.startswith(prefix):
            return line.split(":", 1)[1].strip()
    raise AssertionError(f"{toc} is missing ## {field_name}:")


def test_rc_loot_council_capture_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 RC Loot Council capture tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert CAPTURE_LUA.exists()


def test_child_toc_follows_packaged_child_conventions():
    child = CHILD_TOC.read_text(encoding="utf-8")
    parent = PARENT_TOC.read_text(encoding="utf-8")

    assert _toc_field(CHILD_TOC, "Interface") == _toc_field(PARENT_TOC, "Interface")
    assert _toc_field(CHILD_TOC, "Version") == _toc_field(PARENT_TOC, "Version")
    assert "## Dependencies: SpectrumFederation" in child
    assert "## Group: SpectrumFederation" in child
    assert "## X-SpectrumFederation-Parent: SpectrumFederation" in child
    assert "## SavedVariables: SpectrumFederationRCLootCouncilCaptureDB" in child
    assert "SpectrumFederation_RCLootCouncilCapture" not in parent
    assert "RCLootCouncilCapture" not in parent
    assert "Capture.lua" in child
    assert "RCLootCouncil" not in child.split("## Dependencies:", 1)[1].splitlines()[0]
