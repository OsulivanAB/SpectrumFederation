"""Contract tests for the Cursed Surge Tracker schedule and map rules."""

from __future__ import annotations

import math
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cursed_surge_logic as cst

REPO_ROOT = Path(__file__).resolve().parents[1]
CHILD_ROOT = REPO_ROOT / "SpectrumFederation_CursedSurgeTracker"
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
CHILD_TOC = CHILD_ROOT / "SpectrumFederation_CursedSurgeTracker.toc"
SCHEDULE_LUA = CHILD_ROOT / "Schedule.lua"


def location(area_poi_id):
    return cst.LOCATIONS_BY_POI[area_poi_id]


def row(area_poi_id, start, end, event_id=None, **extra):
    payload = {
        "areaPoiID": area_poi_id,
        "startTime": start,
        "endTime": end,
    }
    if event_id is None:
        event_id = location(area_poi_id)["eventID"]
    payload["eventID"] = event_id
    payload.update(extra)
    return payload


def parents(mapping):
    return lambda map_id: mapping.get(map_id)


def test_lua_constants_match_python_contract():
    assert cst.parse_lua_number("COILED_ISLE_MAP_ID") == 2512
    assert cst.parse_lua_string("FALLBACK_ATLAS") == "UI-EventPoi-venomoustides"
    assert cst.parse_lua_number("LOCATION_STEP_SECONDS") == 2700
    assert cst.parse_lua_number("SAME_LOCATION_RECURRENCE_SECONDS") == 13500
    lua = cst.lua_constants_text()
    for loc in cst.LOCATIONS:
        assert str(loc["areaPoiID"]) in lua
        assert str(loc["eventID"]) in lua
        assert f"{loc['x']:.4f}" in lua
        assert f"{loc['y']:.4f}" in lua


def test_recognizes_map_2512_as_coiled_isle():
    assert cst.is_coiled_isle_map(2512, parents({})) is True


def test_recognizes_child_subzone_ancestry():
    get_parent = parents({2601: 2512, 2512: 2274, 2274: 0})
    assert cst.is_coiled_isle_map(2601, get_parent) is True
    assert cst.is_coiled_isle_map(2512, get_parent) is True


def test_rejects_unrelated_player_maps():
    get_parent = parents({84: 13, 13: 947, 947: 0, 2274: 0})
    assert cst.is_coiled_isle_map(84, get_parent) is False
    assert cst.is_coiled_isle_map(2274, get_parent) is False
    assert cst.is_coiled_isle_map(None, get_parent) is False
    assert cst.is_coiled_isle_map(0, get_parent) is False


def test_filters_scheduler_rows_to_known_area_poi_ids():
    rows = [
        row(8936, 100, 200),
        row(9999, 100, 200, event_id=99),
        {"areaPoiID": 42, "startTime": 1, "endTime": 2, "eventID": 1},
        row(8939, 300, 400),
    ]
    filtered = cst.filter_known_scheduler_rows(rows)
    assert [item["areaPoiID"] for item in filtered] == [8936, 8939]


def test_validates_event_ids_as_secondary_identifiers():
    matching = row(8936, 100, 200, event_id=42)
    conflicting = row(8936, 300, 400, event_id=99)
    event_only = {"eventID": 42, "startTime": 500, "endTime": 600}
    loc = location(8936)
    assert cst.row_matches_location(matching, loc) is True
    assert cst.row_matches_location(conflicting, loc) is False
    assert cst.row_matches_location(event_only, loc) is True
    known = cst.filter_known_scheduler_rows([matching, conflicting, event_only])
    assert known == [matching, event_only]


def test_deduplicates_identical_scheduler_rows():
    first = row(8937, 100, 200)
    duplicate = row(8937, 100, 200)
    different = row(8937, 100, 201)
    result = cst.deduplicate_rows([first, duplicate, different, first])
    assert result == [first, different]


def test_sorts_rows_by_start_time():
    rows = [row(8938, 300, 400), row(8938, 100, 150), row(8938, 200, 250)]
    sorted_rows = cst.sort_rows_by_start_time(rows)
    assert [item["startTime"] for item in sorted_rows] == [100, 200, 300]


def test_selects_active_occurrence():
    rows = [row(8940, 100, 200), row(8940, 400, 500)]
    assert cst.select_active_occurrence(rows, 100)["startTime"] == 100
    assert cst.select_active_occurrence(rows, 199)["startTime"] == 100
    assert cst.select_active_occurrence(rows, 200) is None
    assert cst.select_active_occurrence(rows, 99) is None


def test_allows_multiple_locations_active_simultaneously():
    now = 1000
    rows = [
        row(8939, 900, 1100),
        row(8937, 980, 1200),
        row(8940, 2000, 2300),
    ]
    states = [
        cst.resolve_location_state(location(8939), rows, now, "ready"),
        cst.resolve_location_state(location(8937), rows, now, "ready"),
        cst.resolve_location_state(location(8940), rows, now, "ready"),
    ]
    assert [state["status"] for state in states] == ["active", "active", "inactive"]
    assert sum(1 for state in states if state["active"]) == 2


def test_selects_earliest_future_occurrence():
    rows = [row(8936, 500, 600), row(8936, 200, 300), row(8936, 800, 900)]
    nxt = cst.select_next_occurrence(rows, 350)
    assert nxt["startTime"] == 500


def test_selects_latest_completed_occurrence():
    rows = [row(8936, 100, 200), row(8936, 300, 400), row(8936, 800, 900)]
    prev = cst.select_previous_occurrence(rows, 450)
    assert prev["endTime"] == 400


def test_uses_end_minus_start_instead_of_duration_field():
    payload = row(8938, 1000, 3728, duration=2700)
    assert cst.event_duration(payload) == 2728
    state = cst.resolve_location_state(location(8938), [payload], 1000, "ready")
    assert state["countdownSeconds"] == 2728


def test_inactive_ring_progress_formula_and_boundaries():
    previous_end = 1000
    next_start = 2000
    assert cst.inactive_ring_progress(previous_end, next_start, 1000) == 1
    assert cst.inactive_ring_progress(previous_end, next_start, 1500) == 0.5
    assert cst.inactive_ring_progress(previous_end, next_start, 2000) == 0


def test_clamps_progress_below_zero_and_above_one():
    assert cst.inactive_ring_progress(1000, 2000, 2500) == 0
    assert cst.inactive_ring_progress(1000, 2000, 500) == 1
    assert cst.clamp01(-4) == 0
    assert cst.clamp01(4) == 1


def test_keeps_active_ring_full():
    payload = row(8940, 100, 200)
    state = cst.resolve_location_state(location(8940), [payload], 150, "ready")
    assert state["ringMode"] == "active"
    assert state["ringProgress"] == 1
    assert cst.active_ring_progress() == 1


def test_missing_previous_event_uses_guarded_fallback_or_hides_ring():
    nxt = row(8936, 10_000, 12_728)
    state = cst.resolve_location_state(location(8936), [nxt], 100, "ready")
    assert state["status"] == "inactive"
    assert state["previousEndSource"] == "recurrence"
    empty_next = {"areaPoiID": 8936, "eventID": 42, "startTime": 10_000}
    state = cst.resolve_location_state(location(8936), [empty_next], 100, "ready")
    assert state["status"] == "unavailable"
    assert state["ringVisible"] is False


def test_inferred_previous_end_from_consecutive_rows():
    rows = [
        row(8939, 0, 2728),
        row(8939, 13500, 16228),
    ]
    previous_end, source = cst.resolve_previous_end_time(rows, rows[1], 3000)
    assert source == "scheduler"
    assert previous_end == 2728
    previous_end, source = cst.resolve_previous_end_time([rows[1]], rows[1], 3000)
    assert source == "recurrence"
    assert previous_end == 2728

    future_rows = [
        row(8939, 20000, 22728),
        row(8939, 33500, 36228),
    ]
    previous_end, source = cst.resolve_previous_end_time(future_rows, future_rows[0], 1000)
    assert source == "inferred"
    assert previous_end == 9228


def test_missing_next_event_marks_unavailable_when_not_active():
    rows = [row(8937, 100, 200)]
    state = cst.resolve_location_state(location(8937), rows, 500, "ready")
    assert state["status"] == "unavailable"
    assert state["ringVisible"] is False
    assert state["next"] is None


def test_rejects_zero_zero_live_coordinates():
    assert cst.is_usable_map_position(0, 0) is False
    x, y, source = cst.resolve_coordinates(0.2662, 0.6490, 0, 0)
    assert (x, y, source) == (0.2662, 0.6490, "fixed")


def test_rejects_coordinates_outside_zero_through_one():
    assert cst.is_usable_map_position(-0.1, 0.5) is False
    assert cst.is_usable_map_position(0.5, 1.2) is False
    assert cst.is_usable_map_position(math.nan, 0.5) is False
    assert cst.is_usable_map_position(0.5, math.inf) is False
    _x, _y, source = cst.resolve_coordinates(0.4720, 0.6205, 1.5, 0.2)
    assert source == "fixed"


def test_falls_back_to_fixed_coordinates_and_keeps_valid_live_ones():
    _x, _y, source = cst.resolve_coordinates(0.7098, 0.3191, None, None)
    assert source == "fixed"
    x, y, source = cst.resolve_coordinates(0.7098, 0.3191, 0.71, 0.32)
    assert (x, y, source) == (0.71, 0.32, "live")


def test_atlas_priority():
    assert cst.resolve_atlas("scheduler-atlas", "poi-atlas") == ("scheduler-atlas", "scheduler")
    assert cst.resolve_atlas(None, "poi-atlas") == ("poi-atlas", "poi")
    assert cst.resolve_atlas("", "") == (cst.FALLBACK_ATLAS, "fallback")
    assert cst.resolve_atlas(None, None, None) == (cst.FALLBACK_ATLAS, "fallback")


def test_missing_poi_metadata_still_resolves_fixed_pin():
    loc = location(8938)
    state = cst.resolve_location_state(loc, [], 1, "loading", extras={})
    assert state["x"] == loc["x"]
    assert state["y"] == loc["y"]
    assert state["coordinateSource"] == "fixed"
    assert state["atlas"] == cst.FALLBACK_ATLAS
    assert state["status"] == "loading"


def test_loading_schedule_state_hides_rings():
    state = cst.resolve_location_state(location(8936), [], 100, "loading")
    assert state["status"] == "loading"
    assert state["ringVisible"] is False
    assert state["ringProgress"] is None


def test_unavailable_schedule_state_hides_rings():
    state = cst.resolve_location_state(location(8936), [row(9999, 1, 2, event_id=1)], 100, "ready")
    assert state["status"] == "unavailable"
    assert state["ringVisible"] is False


def test_duration_formatting_under_and_over_one_hour():
    assert cst.format_duration(522) == "08:42"
    assert cst.format_duration(2528) == "42:08"
    assert cst.format_duration(5322) == "1:28:42"
    assert cst.format_duration(7722) == "2:08:42"
    assert cst.format_duration(0) == "00:00"
    assert cst.format_duration(-5) == "00:00"


def test_zone_deactivation_cleanup_policy():
    assert cst.should_process_scheduler(False) is False
    assert cst.should_show_pins(False, 2512) is False
    assert cst.should_show_pins(True, 2274) is False
    assert cst.should_show_pins(True, 2512) is True
    assert cst.should_run_boundary_timer(True, False, 2512) is False
    assert cst.should_run_boundary_timer(True, True, 2512) is True
    assert cst.should_run_tooltip_ticker(True, True, 2512, False) is False
    assert cst.should_run_tooltip_ticker(True, True, 2512, True) is True
    assert cst.should_run_tooltip_ticker(False, True, 2512, True) is False


def test_schedule_lua_does_not_use_duration_field_for_active_length():
    text = SCHEDULE_LUA.read_text(encoding="utf-8")
    assert "Never use the scheduler duration field" in text
    assert "endTime" in text and "startTime" in text


def test_parent_toc_does_not_load_child_files():
    parent = PARENT_TOC.read_text(encoding="utf-8")
    assert "CursedSurgeTracker" not in parent
    assert "SpectrumFederation_CursedSurgeTracker" not in parent
    child = CHILD_TOC.read_text(encoding="utf-8")
    assert "## Dependencies: SpectrumFederation" in child
    assert "## Group: SpectrumFederation" in child
    assert "## Title: Spectrum Federation: Cursed Surge Tracker" in child
    assert "## LoadOnDemand:" not in child
