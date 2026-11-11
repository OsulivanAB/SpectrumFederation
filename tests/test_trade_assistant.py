"""Contract tests for the runtime-only /sf trade assistant (#269)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
ADDON = REPO_ROOT / "SpectrumFederation"
TOC = ADDON / "SpectrumFederation.toc"
LOCALE = ADDON / "locale" / "enUS.lua"
SLASH = ADDON / "modules" / "SlashCommands.lua"
CORE = ADDON / "modules" / "TradeAssistant.lua"
WINDOW = ADDON / "modules" / "UI" / "TradeAssistant" / "Window.lua"
DOCS = REPO_ROOT / "docs" / "reference" / "slash-commands.md"
LUA_TEST = REPO_ROOT / "tests" / "lua" / "trade_assistant_tests.lua"
CHILD_TOCS = (
    REPO_ROOT / "SpectrumFederation_CursedSurgeTracker" / "SpectrumFederation_CursedSurgeTracker.toc",
    REPO_ROOT / "SpectrumFederation_RCLootCouncilIntegration" / "SpectrumFederation_RCLootCouncilIntegration.toc",
)

EXPECTED_LOCALE_KEYS = {
    "TRADE_ASSISTANT_TITLE",
    "TRADE_ASSISTANT_HINT",
    "TRADE_ASSISTANT_EMPTY",
    "TRADE_ASSISTANT_ONE_ITEM",
    "TRADE_ASSISTANT_ITEMS",
    "TRADE_ASSISTANT_RANGE_IN",
    "TRADE_ASSISTANT_RANGE_OUT",
    "TRADE_ASSISTANT_RANGE_UNKNOWN",
    "TRADE_ASSISTANT_ERR_ITEM",
    "TRADE_ASSISTANT_ERR_QUANTITY",
    "TRADE_ASSISTANT_ERR_NOT_IN_RAID",
    "TRADE_ASSISTANT_ERR_NO_MEMBERS",
    "TRADE_ASSISTANT_ERR_INSUFFICIENT",
    "TRADE_ASSISTANT_QUEUED",
    "TRADE_ASSISTANT_SLASH_DESC",
}


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute Trade Assistant production tests")


def test_trade_assistant_packaging_and_localization_contract():
    toc = TOC.read_text(encoding="utf-8")
    assert "## Version: 1.5.19-beta.6" in toc
    for child_toc in CHILD_TOCS:
        assert "## Version: 1.5.19-beta.6" in child_toc.read_text(encoding="utf-8")
    assert CORE.exists()
    assert WINDOW.exists()

    toc_entries = [line.strip() for line in toc.splitlines() if line.strip() and not line.startswith("##")]
    name_util = toc_entries.index("modules/NameUtil.lua")
    slash = toc_entries.index("modules/SlashCommands.lua")
    core = toc_entries.index("modules/TradeAssistant.lua")
    window = toc_entries.index("modules/UI/TradeAssistant/Window.lua")
    message_helpers = toc_entries.index("modules/MessageHelpers.lua")
    assert name_util < slash < core < window < message_helpers

    locale = LOCALE.read_text(encoding="utf-8")
    for key in EXPECTED_LOCALE_KEYS:
        assert f'L["{key}"]' in locale

    slash_source = SLASH.read_text(encoding="utf-8")
    assert "preserveArgs" in slash_source
    core_source = CORE.read_text(encoding="utf-8")
    window_source = WINDOW.read_text(encoding="utf-8")
    assert "{ preserveArgs = true }" in core_source
    assert "C_Timer.NewTicker" in window_source
    assert "StopRangeTicker" in window_source

    for source in (core_source, window_source):
        assert "SavedVariables" not in source
        assert "SpectrumFederationCharDB" not in source

    docs = DOCS.read_text(encoding="utf-8")
    assert "/sf trade [item link] [quantity]" in docs
    assert "Trade Assistant" in docs
    assert "runtime-only" in docs


def test_trade_assistant_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TEST)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Trade Assistant tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
