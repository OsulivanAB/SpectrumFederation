"""Run production Lua Raid Consumables tests."""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
TESTS = REPO_ROOT / "tests" / "lua" / "consumables_tests.lua"
OBSERVATION_TESTS = REPO_ROOT / "tests" / "lua" / "consumables_observation_tests.lua"
RUNTIME = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesRuntime.lua"
WORKFLOW = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesWorkflow.lua"
OBSERVATION = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesObservation.lua"
BANK_LOG = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "ConsumablesBankLog.lua"
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


def test_consumables_observation_production_lua():
    result = subprocess.run(
        [_lua51(), str(OBSERVATION_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Raid Consumables observation tests failed\n"
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
    observation = OBSERVATION.read_text(encoding="utf-8")
    bank_log = BANK_LOG.read_text(encoding="utf-8")
    assert "function O.ReconcileSnapshot" in observation
    assert "PENDING_TTL_SECONDS" in observation
    assert "QueryGuildBankLog" in bank_log
    assert 'TryRegister(frame, "GUILDBANKLOG_UPDATE")' in bank_log
    assert "GetGuildBankTransaction" in bank_log
    assert "GetNumGuildBankTransactions" in bank_log
    assert "CommitEvents" not in observation
    assert "DepositEvents" not in observation
    assert "CommitEvents" not in bank_log
    assert "DepositEvents" not in bank_log
    assert "SF.ConsumablesBankLog:Init()" in runtime
    assert "ConsumablesBankLog:OnProfileMaybeChanged" in runtime
    assert "ScheduleRescan" not in bank_log
    assert "EMPTY_CONTEXT_CONTINUITY_SECONDS" in observation
    assert "tonumber(existing.generation) ~= tonumber(evidence.generation)" in observation
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
    assert "function Controls.ConsumableRequestedNameColumnWidth" in controls
    assert "function Controls.ConsumableRequestedGoalEditGap" in controls
    assert 'Controls.CONSUMABLE_REQUESTED_CONTROL_ORDER = { "text", "goalLabel", "goalEdit", "remove" }' in controls
    assert "goalEditInputInset" in controls
    assert "LayoutRowColumns" in controls
    assert "ApplyScrollAndColumns" in controls
    assert "nameColumnWidth" in controls
    assert "C.ValidGoal" in page
    # Enter must clear focus only; focus-loss is the sole goal-commit path.
    enter_at = controls.find('r.GoalEdit:SetScript("OnEnterPressed"')
    lost_at = controls.find('r.GoalEdit:SetScript("OnEditFocusLost"')
    assert 0 <= enter_at < lost_at
    enter_body = controls[enter_at:lost_at]
    assert "ClearFocus()" in enter_body
    assert "CommitGoal()" not in enter_body
    assert "CommitGoal()" in controls[lost_at : lost_at + 120]
    # Shared name column with Goal label centered on the input.
    flow_at = controls.find("local function LayoutRowColumns")
    assert flow_at != -1
    flow_body = controls[flow_at : flow_at + 1200]
    assert "r.GoalEdit:SetPoint(" in flow_body
    assert "r.Text" in flow_body[flow_body.find("r.GoalEdit:SetPoint(") : flow_body.find("r.GoalEdit:SetPoint(") + 160]
    assert 'r.GoalLabel:SetPoint("RIGHT", r.GoalEdit, "LEFT"' in flow_body
    assert 'r.Remove:SetPoint("LEFT", r.GoalEdit, "RIGHT"' in flow_body
    assert 'r.Remove:SetPoint("LEFT", r.Text, "RIGHT"' not in flow_body
    assert "effectiveGoalEditGap" in flow_body
    assert "nameColumnWidth" in flow_body


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


def test_consumables_donation_helper_locale_keys_and_toc_order():
    toc = (REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc").read_text(encoding="utf-8")
    locale = (REPO_ROOT / "SpectrumFederation" / "locale" / "enUS.lua").read_text(encoding="utf-8")
    domain = (
        REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Consumables.lua"
    ).read_text(encoding="utf-8")
    runtime = RUNTIME.read_text(encoding="utf-8")

    locale_at = toc.find("locale/enUS.lua")
    runtime_at = toc.find("modules/LootHelper/ConsumablesRuntime.lua")
    domain_at = toc.find("modules/LootHelper/Consumables.lua")
    observation_at = toc.find("modules/LootHelper/ConsumablesObservation.lua")
    bank_log_at = toc.find("modules/LootHelper/ConsumablesBankLog.lua")
    assert locale_at != -1, "locale/enUS.lua must be listed in the parent TOC"
    assert locale_at < domain_at < runtime_at
    assert domain_at < observation_at < bank_log_at < runtime_at

    for key in (
        "RAID_SUPPLIES_OVERALL_PROGRESS",
        "RAID_SUPPLIES_NO_GOALS_CONFIGURED",
        "RAID_SUPPLIES_NO_GOAL",
        "RAID_SUPPLIES_GOAL_ALREADY_MET",
    ):
        assert f'L["{key}"]' in locale, key
        assert key in domain or key in runtime, key

    assert "function ns.LocaleText" in locale
    assert 'Loc("RAID_SUPPLIES_OVERALL_PROGRESS"' in runtime
    assert 'Loc("RAID_SUPPLIES_NO_GOAL"' in runtime
    assert 'Loc("RAID_SUPPLIES_GOAL_ALREADY_MET"' in domain
    assert "row.boundItemId" in runtime
    assert "sameItem" in runtime
    assert "local REVIEW_WIDTH = 256" in runtime
    assert "frame:SetSize(REVIEW_WIDTH, REVIEW_DEFAULT_HEIGHT)" in runtime
    assert "frame:SetSize(480," not in runtime
    assert "REVIEW_ROW_WIDTH" in runtime
    assert "REVIEW_DEPOSIT_WIDTH" in runtime
