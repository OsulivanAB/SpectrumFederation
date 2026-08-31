"""Run production Lua Raid Equipment Policy and CheckRun tests."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
POLICY = REPO_ROOT / "SpectrumFederation" / "modules" / "RaidEquipment" / "Policy.lua"
CHECK_RUN = REPO_ROOT / "SpectrumFederation" / "modules" / "RaidEquipment" / "CheckRun.lua"
POLICY_TESTS = REPO_ROOT / "tests" / "lua" / "raid_equipment_policy_tests.lua"
RUN_TESTS = REPO_ROOT / "tests" / "lua" / "raid_check_run_tests.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Raid Equipment tests")


def _run_lua(test_file: Path, label: str) -> None:
    result = subprocess.run(
        [_lua51(), str(test_file)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            f"lua5.1 {label} tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout


def test_raid_equipment_policy_production_lua():
    _run_lua(POLICY_TESTS, "Raid Equipment Policy")
    assert POLICY.exists()


def test_raid_check_run_production_lua():
    _run_lua(RUN_TESTS, "Raid Check run")
    assert CHECK_RUN.exists()


def test_parent_toc_loads_raid_equipment_modules():
    parent = PARENT_TOC.read_text(encoding="utf-8")
    assert "modules/RaidEquipment/Policy.lua" in parent
    assert "modules/RaidEquipment/CheckRun.lua" in parent
    assert parent.index("modules/RaidEquipment/Policy.lua") < parent.index("modules/RaidCheck.lua")
    assert parent.index("modules/RaidEquipment/CheckRun.lua") < parent.index("modules/RaidCheck.lua")
    assert "modules/UI/Settings/Pages/RaidEquipment.lua" in parent


def test_raid_check_does_not_consume_persisted_equipment_snapshots():
    raid_check = (REPO_ROOT / "SpectrumFederation" / "modules" / "RaidCheck.lua").read_text(
        encoding="utf-8"
    )
    profiles = (REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Profiles.lua").read_text(
        encoding="utf-8"
    )
    policy = POLICY.read_text(encoding="utf-8")
    check_run = CHECK_RUN.read_text(encoding="utf-8")

    persist = raid_check.split("local function PersistProfileEquipmentSnapshot", 1)[1]
    persist = persist.split("local function GetProfileEquipmentSnapshot", 1)[0]
    assert "return false" in persist
    assert "_raidCheckEquipmentSnapshots" not in persist
    assert "SetRaidCheckEquipmentSnapshot" not in persist

    assert "function LootProfile:SetRaidCheckEquipmentSnapshot(memberId, snapshot)" in profiles
    assert "self._raidCheckEquipmentSnapshots[memberId] = snapshotCopy" in profiles

    assert "GetRaidCheckEquipmentSnapshot" not in policy
    assert "GetRaidCheckEquipmentSnapshot" not in check_run
    assert "_raidCheckEquipmentSnapshots" not in policy
    assert "_raidCheckEquipmentSnapshots" not in check_run
    assert "CheckRun.ClassifyRun(run, now, state.lastGood)" in raid_check
    assert "GetProfileEquipmentSnapshot(" not in raid_check.split(
        "function RC:_SettleAdhocRun", 1
    )[1]
    assert "GetRaidCheckEquipmentSnapshot" not in raid_check.split(
        "function RC:_SettleAdhocRun", 1
    )[1]
