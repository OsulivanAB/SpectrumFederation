"""Contract tests for Raid Check item-link parsing and reporting rules.

These tests do not run inside WoW. They lock the item-string field layout and
reporting behavior used by SpectrumFederation/modules/RaidCheck.lua so gem,
enchant, and admin-output regressions can be caught without the client.
"""

from __future__ import annotations

import re
from pathlib import Path

RAID_CHECK_LUA = (
    Path(__file__).resolve().parents[1]
    / "SpectrumFederation"
    / "modules"
    / "RaidCheck.lua"
)


def extract_item_string(link: str) -> str | None:
    match = re.search(r"item:([-\d:]+)", link)
    if not match:
        return None
    return match.group(1)


def item_fields(link: str) -> list[str]:
    item_string = extract_item_string(link)
    if item_string is None:
        return []
    return item_string.split(":")


def parse_enchant_id(link: str) -> str | None:
    fields = item_fields(link)
    if len(fields) < 2:
        return None
    enchant_id = fields[1]
    if enchant_id and enchant_id not in ("", "0"):
        return enchant_id
    return None


def count_gems_filled_from_link(link: str) -> int:
    fields = item_fields(link)
    filled = 0
    for idx in range(2, min(6, len(fields))):
        gem_field = fields[idx]
        if gem_field and gem_field not in ("", "0"):
            filled += 1
    return filled


def is_gem_present_in_socket(link: str, socket_index: int) -> bool:
    fields = item_fields(link)
    field_index = 1 + socket_index  # gem 1 is fields[2]
    if field_index >= len(fields):
        return False
    gem_field = fields[field_index]
    return bool(gem_field and gem_field not in ("", "0"))


def has_missing_gems(link: str, socket_count: int) -> bool:
    if socket_count <= 0:
        return False
    for index in range(1, socket_count + 1):
        if not is_gem_present_in_socket(link, index):
            return True
    return False


def is_link_potentially_incomplete(link: str, has_item_evidence: bool) -> bool:
    fields = item_fields(link)
    if not fields:
        return False
    if len(fields) < 7:
        return True
    for value in fields[1:7]:
        if value and value not in ("", "0"):
            return False
    return has_item_evidence


def format_admin_missing_lines(mode_label: str, results: list[dict], whisper_enabled: bool) -> list[str]:
    missing = [entry for entry in results if entry.get("missing")]
    if not missing:
        return []

    lines = [f"[{mode_label}] Players missing enchants/gems:"]
    for entry in missing:
        suffix = ""
        if whisper_enabled and entry.get("whispered_missing"):
            suffix = " (whispered)"
        elif whisper_enabled and entry.get("already_whispered"):
            suffix = " (already whispered today)"
        lines.append(f"  {entry['name']} - {entry['missing']}{suffix}")
    return lines


ENCHANTED_GEMMED_LINK = "|cffa335ee|Hitem:12345:6789:111:222:333:0:0:0:80:::|h[Test Item]|h|r"
EMPTY_SOCKET_LINK = "|cffa335ee|Hitem:12345:6789:111:0:0:0:0:0:80:::|h[Test Item]|h|r"
STUB_LINK = "|cffffffff|Hitem:12345:0:0:0:0:0:0:0:80:::|h[Test Item]|h|r"
UNENCHANTED_COMPLETE_LINK = "|cffa335ee|Hitem:12345:0:111:222:0:0:44:0:80:::|h[Test Item]|h|r"


def test_parse_enchant_id_from_populated_link():
    assert parse_enchant_id(ENCHANTED_GEMMED_LINK) == "6789"
    assert parse_enchant_id(STUB_LINK) is None
    assert parse_enchant_id("not-a-link") is None


def test_count_filled_gems_from_item_string_fields():
    assert count_gems_filled_from_link(ENCHANTED_GEMMED_LINK) == 3
    assert count_gems_filled_from_link(EMPTY_SOCKET_LINK) == 1
    assert count_gems_filled_from_link(STUB_LINK) == 0


def test_each_socket_requires_its_own_gem():
    # Two sockets: first filled, second empty.
    assert has_missing_gems(EMPTY_SOCKET_LINK, socket_count=2) is True
    # Three sockets, all filled in the first three gem fields.
    assert has_missing_gems(ENCHANTED_GEMMED_LINK, socket_count=3) is False
    # No sockets means gem checks are skipped.
    assert has_missing_gems(ENCHANTED_GEMMED_LINK, socket_count=0) is False


def test_stub_links_with_item_evidence_are_incomplete():
    assert is_link_potentially_incomplete(STUB_LINK, has_item_evidence=True) is True
    assert is_link_potentially_incomplete(UNENCHANTED_COMPLETE_LINK, has_item_evidence=True) is False
    assert is_link_potentially_incomplete(ENCHANTED_GEMMED_LINK, has_item_evidence=True) is False


def test_admin_missing_summary_is_independent_of_whisper_setting():
    results = [
        {"name": "Alice", "missing": "Head Enchant", "whispered_missing": True},
        {"name": "Bob", "missing": "Chest Gem", "already_whispered": True},
        {"name": "Cara", "inspect_pending": "Loading"},
    ]

    without_whispers = format_admin_missing_lines("Pre-Raid Check", results, whisper_enabled=False)
    with_whispers = format_admin_missing_lines("Pre-Raid Check", results, whisper_enabled=True)

    assert without_whispers[0] == "[Pre-Raid Check] Players missing enchants/gems:"
    assert "Alice - Head Enchant" in without_whispers[1]
    assert "Bob - Chest Gem" in without_whispers[2]
    assert len(without_whispers) == 3

    assert with_whispers[0] == without_whispers[0]
    assert with_whispers[1].endswith("(whispered)")
    assert with_whispers[2].endswith("(already whispered today)")
    assert any("Cara" in line for line in with_whispers) is False


def test_raid_check_lua_keeps_admin_summary_ungated():
    source = RAID_CHECK_LUA.read_text(encoding="utf-8")
    assert "EmitAdminMissingSummary" in source
    assert "if not ShouldWhisper(" not in source
    assert source.count("EmitAdminMissingSummary") >= 2


def test_raid_check_lua_checks_each_socket_for_a_gem():
    source = RAID_CHECK_LUA.read_text(encoding="utf-8")
    has_missing_gems_fn = source.split("local function HasMissingGems(link)", 1)[1]
    has_missing_gems_fn = has_missing_gems_fn.split("local function GetDetailedItemLevelSafe", 1)[0]
    assert "for i = 1, sockets do" in has_missing_gems_fn
    assert "if not IsGemPresentInSocket(link, i) then" in has_missing_gems_fn
    assert "gemsFromLink >= sockets" not in has_missing_gems_fn


def test_raid_check_lua_forwards_has_equipment_data():
    source = RAID_CHECK_LUA.read_text(encoding="utf-8")
    inspect_state_fn = source.split("function RC:_GetTroubleshootingInspectState", 1)[1]
    inspect_state_fn = inspect_state_fn.split("local function SendWhisper", 1)[0]
    has_equipment_data_def = source.find("local function HasEquipmentData(slotsByInventory)")
    inspect_state_def = source.find("function RC:_GetTroubleshootingInspectState")
    assert has_equipment_data_def != -1
    assert inspect_state_def != -1
    assert has_equipment_data_def < inspect_state_def
    assert "HasEquipmentData(cacheEntry.slotsByInventory)" in inspect_state_fn
    assert source.count("local function HasEquipmentData(slotsByInventory)") == 1
