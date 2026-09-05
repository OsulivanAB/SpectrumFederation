"""Run production Lua RC Loot Council Integration tests and child-addon TOC checks."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
CHILD_ROOT = REPO_ROOT / "SpectrumFederation_RCLootCouncilIntegration"
CHILD_TOC = CHILD_ROOT / "SpectrumFederation_RCLootCouncilIntegration.toc"
INTEGRATION_LUA = CHILD_ROOT / "Integration.lua"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "rc_loot_council_integration_tests.lua"
CAPTURE_ROOT = REPO_ROOT / "SpectrumFederation_RCLootCouncilCapture"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production RC integration tests")


def _toc_field(toc: Path, field_name: str) -> str:
    for line in toc.read_text(encoding="utf-8").splitlines():
        prefix = f"## {field_name}:"
        if line.startswith(prefix):
            return line.split(":", 1)[1].strip()
    raise AssertionError(f"{toc} is missing ## {field_name}:")


def test_rc_loot_council_integration_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 RC Loot Council Integration tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert INTEGRATION_LUA.exists()


def test_child_toc_follows_packaged_child_conventions():
    child = CHILD_TOC.read_text(encoding="utf-8")
    parent = PARENT_TOC.read_text(encoding="utf-8")

    assert _toc_field(CHILD_TOC, "Interface") == _toc_field(PARENT_TOC, "Interface")
    assert _toc_field(CHILD_TOC, "Version") == _toc_field(PARENT_TOC, "Version")
    assert "## Dependencies: SpectrumFederation" in child
    assert "## OptionalDeps: RCLootCouncil" in child
    assert "## Group: SpectrumFederation" in child
    assert "## X-SpectrumFederation-Parent: SpectrumFederation" in child
    assert "## X-SpectrumFederation-Settings-Host: lootHelper" in child
    assert "## SavedVariables:" not in child
    assert "SpectrumFederation_RCLootCouncilIntegration" not in parent
    assert "RCLootCouncilIntegration" not in parent
    assert "Integration.lua" in child
    assert "RCLootCouncil" not in child.split("## Dependencies:", 1)[1].splitlines()[0]


def test_temporary_capture_addon_is_removed():
    assert not CAPTURE_ROOT.exists()
    assert not (REPO_ROOT / "tests" / "test_rc_loot_council_capture.py").exists()
    assert not (REPO_ROOT / "tests" / "lua" / "rc_loot_council_capture_tests.lua").exists()
    assert not (REPO_ROOT / "docs" / "development" / "rc-loot-council-capture.md").exists()
