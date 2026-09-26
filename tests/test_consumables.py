"""Run production Lua Raid Consumables tests."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
TESTS = REPO_ROOT / "tests" / "lua" / "consumables_tests.lua"
RUNTIME = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesRuntime.lua"
WORKFLOW = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesWorkflow.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Raid Consumables tests")


def test_consumables_production_lua():
    result = subprocess.run(
        [_lua51(), str(TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Raid Consumables tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout


def test_consumables_trade_never_auto_accepts():
    root = REPO_ROOT / "SpectrumFederation" / "modules"
    sources = []
    for path in root.rglob("Consumables*.lua"):
        sources.append(path.read_text(encoding="utf-8"))
    combined = "\n".join(sources)
    assert "AcceptTrade" not in combined
    assert "SetScript(\"OnUpdate\"" not in combined
    assert "EventsFromUnsupportedInventoryDecrease" in WORKFLOW.read_text(encoding="utf-8")
    if RUNTIME.exists():
        runtime = RUNTIME.read_text(encoding="utf-8")
        assert "AcceptTrade" not in runtime
        assert "OnUpdate" not in runtime


def test_consumables_snapshot_merge_is_inside_import():
    profiles = (
        REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Profiles.lua"
    ).read_text(encoding="utf-8")
    import_at = profiles.find("function LootProfile:ImportSnapshot")
    merge_at = profiles.find("function LootProfile:MergeLogTables")
    assert import_at != -1 and merge_at > import_at
    import_body = profiles[import_at:merge_at]
    merge_body = profiles[merge_at:]
    assert "snapshot.consumables" in import_body
    assert "snapshot.consumables" not in merge_body
