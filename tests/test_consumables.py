"""Run production Lua Raid Consumables tests."""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
TESTS = REPO_ROOT / "tests" / "lua" / "consumables_tests.lua"
RUNTIME = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesRuntime.lua"
WORKFLOW = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesWorkflow.lua"
SYNC_TRANSPORT = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelperSync" / "19_Consumables.lua"


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
    assert re.search(r"(?m)^\d+ passed, 0 failed$", result.stdout), result.stdout


def test_consumables_runtime_is_guild_bank_deposit_only():
    root = REPO_ROOT / "SpectrumFederation" / "modules"
    paths = list(root.rglob("Consumables*.lua")) + [SYNC_TRANSPORT]
    combined = "\n".join(path.read_text(encoding="utf-8") for path in paths)
    for removed in (
        "AcceptTrade",
        "InitiateTrade",
        "ClickTradeButton",
        "TRADE_",
        "OnUpdate",
        "NewTicker",
        "AddCrafter",
        "BeginTrade",
        "NoteGuildBankPickup",
        "TradeEvents",
        "WithdrawEvents",
    ):
        assert removed not in combined, removed
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "function W.DepositEvents" in workflow
    runtime = RUNTIME.read_text(encoding="utf-8")
    assert 'TryRegister(frame, "GUILDBANKBAGSLOTS_CHANGED")' in runtime
    assert "PickupGuildBankItem(work.tab" in runtime
    assert "C_SpellBook.IsSpellKnown" in runtime
    assert "SecureActionButtonTemplate" in runtime
    assert 'TryRegister(frame, "SPELL_UPDATE_COOLDOWN")' in runtime
    assert "isActive" in runtime
    assert "ScheduleMobileCooldownWatch" in runtime
    assert "ConsumeBannerBankNavigation" in runtime
    assert "BeginBannerBankNavigation" in runtime
    assert "SyncReviewWithGuildBank" in runtime
    assert "HideReviewForBankLifecycle" in runtime
    assert "UIPanelCloseButton" not in runtime
    assert "HasReminderPath" in (
        REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesRouting.lua"
    ).read_text(encoding="utf-8")
    assert "self.dismissed" not in runtime
    assert "OnDismiss" not in runtime
    # Prefer known-spell detection for guild perks; IsSpellInSpellBook is only a fallback.
    known_at = runtime.find("C_SpellBook.IsSpellKnown")
    in_book_at = runtime.find("C_SpellBook.IsSpellInSpellBook")
    assert known_at != -1 and in_book_at != -1 and known_at < in_book_at
    # Reminder UI must target SF.LootHelperWindow.Window, not the parent namespace.
    assert "function Runtime:LootHelperWindow" in runtime
    assert "return lh and lh.Window or nil" in runtime
    assert "local window = SF.LootHelperWindow\n" not in runtime


def test_consumables_goal_editor_guards_are_present():
    controls = (
        REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "Control" / "Controls.lua"
    ).read_text(encoding="utf-8")
    page = (
        REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "Pages" / "Consumables.lua"
    ).read_text(encoding="utf-8")
    assert "function Controls.ShouldCommitConsumableGoal" in controls
    assert "__sfLastCommittedText" in controls
    assert "__sfBoundItemId" in controls
    assert "__sfCancelCommit" in controls
    assert "function Controls.ConsumableRequestedTextMaxWidth" in controls
    assert "function Controls.ConsumableRequestedTextWidth" in controls
    assert "function Controls.ConsumableRequestedGoalEditGap" in controls
    assert 'Controls.CONSUMABLE_REQUESTED_CONTROL_ORDER = { "text", "goalLabel", "goalEdit", "remove" }' in controls
    assert "goalEditInputInset" in controls
    assert "LayoutRowFlow" in controls
    assert "ApplyScrollAndFlow" in controls
    assert "C.ValidGoal" in page
    # Enter must clear focus only; focus-loss is the sole goal-commit path.
    enter_at = controls.find('r.GoalEdit:SetScript("OnEnterPressed"')
    lost_at = controls.find('r.GoalEdit:SetScript("OnEditFocusLost"')
    assert 0 <= enter_at < lost_at
    enter_body = controls[enter_at:lost_at]
    assert "ClearFocus()" in enter_body
    assert "CommitGoal()" not in enter_body
    assert "CommitGoal()" in controls[lost_at : lost_at + 120]
    # Flowing order with Goal label centered on the input (not chained off the name).
    flow_at = controls.find("local function LayoutRowFlow")
    assert flow_at != -1
    flow_body = controls[flow_at : flow_at + 1200]
    assert "r.GoalEdit:SetPoint(" in flow_body
    assert "r.Text" in flow_body[flow_body.find("r.GoalEdit:SetPoint(") : flow_body.find("r.GoalEdit:SetPoint(") + 160]
    assert 'r.GoalLabel:SetPoint("RIGHT", r.GoalEdit, "LEFT"' in flow_body
    assert 'r.Remove:SetPoint("LEFT", r.GoalEdit, "RIGHT"' in flow_body
    assert 'r.Remove:SetPoint("LEFT", r.Text, "RIGHT"' not in flow_body
    assert "effectiveGoalEditGap" in flow_body


def test_consumable_requested_list_layout_production_lua():
    layout_tests = REPO_ROOT / "tests" / "lua" / "consumable_requested_list_layout_tests.lua"
    result = subprocess.run(
        [_lua51(), str(layout_tests)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Consumable requested-list layout tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert re.search(r"(?m)^\d+ passed, 0 failed$", result.stdout), result.stdout


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
