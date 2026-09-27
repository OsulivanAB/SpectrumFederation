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
RANGED_OFFHAND_TESTS = REPO_ROOT / "tests" / "lua" / "raid_equipment_ranged_offhand_tests.lua"
RUN_TESTS = REPO_ROOT / "tests" / "lua" / "raid_check_run_tests.lua"
FRESH_SNAPSHOT_TESTS = REPO_ROOT / "tests" / "lua" / "raid_equipment_fresh_snapshot_tests.lua"
STABILITY_TESTS = REPO_ROOT / "tests" / "lua" / "raid_equipment_stability_tests.lua"
PRESENCE_TESTS = REPO_ROOT / "tests" / "lua" / "raid_check_presence_tests.lua"
ITEM_LEVEL_CONFIG_TESTS = REPO_ROOT / "tests" / "lua" / "raid_check_item_level_config_tests.lua"
GLANCE_TESTS = REPO_ROOT / "tests" / "lua" / "roster_glance_tests.lua"
SCHEMA = REPO_ROOT / "SpectrumFederation" / "modules" / "Settings" / "Schema.lua"
RAID_EQUIPMENT_PAGE = (
    REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "Pages" / "RaidEquipment.lua"
)


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


def test_raid_equipment_ranged_offhand_production_lua():
    _run_lua(RANGED_OFFHAND_TESTS, "Raid Equipment ranged off hand")
    assert RANGED_OFFHAND_TESTS.exists()


def test_raid_check_run_production_lua():
    _run_lua(RUN_TESTS, "Raid Check run")
    assert CHECK_RUN.exists()


def test_raid_equipment_fresh_install_snapshot_production_lua():
    _run_lua(FRESH_SNAPSHOT_TESTS, "Raid Equipment fresh snapshot")
    assert RAID_EQUIPMENT_PAGE.exists()


def test_raid_equipment_stability_production_lua():
    _run_lua(STABILITY_TESTS, "Raid Equipment stability")
    assert RAID_EQUIPMENT_PAGE.exists()


def test_raid_check_item_level_config_production_lua():
    _run_lua(ITEM_LEVEL_CONFIG_TESTS, "Raid Check item level config")
    assert ITEM_LEVEL_CONFIG_TESTS.exists()


def test_item_level_capture_uses_blizzard_equipped_value():
    raid_check = (REPO_ROOT / "SpectrumFederation" / "modules" / "RaidCheck.lua").read_text(
        encoding="utf-8"
    )
    page = RAID_EQUIPMENT_PAGE.read_text(encoding="utf-8")
    assert "C_PaperDollInfo.GetAverageItemLevel" in raid_check
    assert "C_PaperDollInfo.GetInspectItemLevel" in raid_check
    assert "CalculateAverageItemLevel" not in raid_check
    assert "overallEquippedItemLevel" in raid_check
    assert "ReevaluateFrozenRunPolicies" in raid_check
    profiles = (REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Profiles.lua").read_text(
        encoding="utf-8"
    )
    routing = (
        REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelperSync" / "13_Routing.lua"
    ).read_text(encoding="utf-8")
    assert "PublishRaidCheckItemLevelPolicy(self)" in profiles
    assert "RAID_CHECK_ILVL_SET" in routing
    assert "RAID_CHECK_ILVL_REQ" in routing
    inspect_ready = raid_check.split("function RC:_HandleInspectReady", 1)[1]
    inspect_ready = inspect_ready.split("\nfunction RC:", 1)[0]
    local_capture = raid_check.split("elseif player and IsSelfUnit(unit) then", 1)[1]
    local_capture = local_capture.split("function RC:_ApplyCheckConsequences", 1)[0]
    assert 'CheckRun.MarkAttempt(player, "incomplete", true)' in local_capture
    assert "_InvalidateLocalTroubleshootingSnapshot()" in local_capture
    assert "PlayerNeedsMoreInspects(player)" in local_capture
    assert "KeepKnownOverallItemLevel(" in inspect_ready
    assert inspect_ready.index("KeepKnownOverallItemLevel(") < inspect_ready.index(
        "RecalculateCapturedSummary(captured)"
    )
    assert "entry.averageItemLevel" not in inspect_ready.split("KeepKnownOverallItemLevel(", 1)[1].split(
        ")", 1
    )[0]
    assert "SetAuditItemLevelPulse(dataRow.ItemLevel, belowMinimum)" in page
    assert "SetAuditItemLevelPulse(dataRow" not in page.replace(
        "SetAuditItemLevelPulse(dataRow.ItemLevel, belowMinimum)",
        "",
    )


def test_raid_check_presence_production_lua():
    _run_lua(PRESENCE_TESTS, "Raid Check presence")
    assert PRESENCE_TESTS.exists()


def test_roster_glance_production_lua():
    _run_lua(GLANCE_TESTS, "Loot Helper glance roster")
    assert GLANCE_TESTS.exists()


def test_raid_equipment_auto_refresh_defaults_off():
    schema = SCHEMA.read_text(encoding="utf-8")
    assert "raidCheckAuditAutoRefresh = false" in schema


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
    assert "local frozenLastGood = ReevaluateFrozenRunPolicies(run, state.lastGood)" in raid_check
    assert "CheckRun.ClassifyRun(run, now, frozenLastGood)" in raid_check
    assert "GetProfileEquipmentSnapshot(" not in raid_check.split(
        "function RC:_SettleAdhocRun", 1
    )[1]
    assert "GetRaidCheckEquipmentSnapshot" not in raid_check.split(
        "function RC:_SettleAdhocRun", 1
    )[1]
