"""Python contract of SpectrumFederation_CursedSurgeTracker/Schedule.lua.

These helpers do not run inside WoW. They lock schedule-state, map, atlas,
coordinate, and duration rules so regressions can be caught without the client.
"""

from __future__ import annotations

import math
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CONSTANTS_LUA = REPO_ROOT / "SpectrumFederation_CursedSurgeTracker" / "Constants.lua"

COILED_ISLE_MAP_ID = 2512
FALLBACK_ATLAS = "UI-EventPoi-venomoustides"
LOCATION_STEP_SECONDS = 2700
SAME_LOCATION_RECURRENCE_SECONDS = 13500
ROTATION_AREA_POI_IDS = (8939, 8937, 8940, 8938, 8936)
LOCATIONS = (
    {"eventID": 42, "areaPoiID": 8936, "x": 0.2662, "y": 0.6490},
    {"eventID": 43, "areaPoiID": 8940, "x": 0.4720, "y": 0.6205},
    {"eventID": 44, "areaPoiID": 8939, "x": 0.7098, "y": 0.3191},
    {"eventID": 45, "areaPoiID": 8938, "x": 0.4535, "y": 0.2862},
    {"eventID": 46, "areaPoiID": 8937, "x": 0.6747, "y": 0.7789},
)
LOCATIONS_BY_POI = {row["areaPoiID"]: row for row in LOCATIONS}
POI_BY_EVENT_ID = {row["eventID"]: row["areaPoiID"] for row in LOCATIONS}


def is_finite_number(value) -> bool:
    return isinstance(value, (int, float)) and math.isfinite(value)


def is_usable_map_position(x, y) -> bool:
    if not is_finite_number(x) or not is_finite_number(y):
        return False
    if x < 0 or x > 1 or y < 0 or y > 1:
        return False
    if x == 0 and y == 0:
        return False
    return True


def resolve_coordinates(fixed_x, fixed_y, live_x, live_y):
    if is_usable_map_position(live_x, live_y):
        return live_x, live_y, "live"
    if is_usable_map_position(fixed_x, fixed_y):
        return fixed_x, fixed_y, "fixed"
    return None, None, None


def resolve_atlas(scheduler_atlas, poi_atlas, fallback_atlas=FALLBACK_ATLAS):
    if isinstance(scheduler_atlas, str) and scheduler_atlas:
        return scheduler_atlas, "scheduler"
    if isinstance(poi_atlas, str) and poi_atlas:
        return poi_atlas, "poi"
    if isinstance(fallback_atlas, str) and fallback_atlas:
        return fallback_atlas, "fallback"
    return FALLBACK_ATLAS, "fallback"


def clamp01(value):
    if not is_finite_number(value):
        return 0
    return max(0.0, min(1.0, float(value)))


def is_map_in_ancestry(map_id, target_id, get_parent_map_id):
    if not is_finite_number(map_id) or not is_finite_number(target_id):
        return False
    if map_id == target_id:
        return True
    if not callable(get_parent_map_id):
        return False
    seen = set()
    current = map_id
    guard = 0
    while current and current != 0 and current not in seen and guard < 32:
        if current == target_id:
            return True
        seen.add(current)
        current = get_parent_map_id(current)
        guard += 1
    return current == target_id


def is_coiled_isle_map(map_id, get_parent_map_id=None):
    return is_map_in_ancestry(map_id, COILED_ISLE_MAP_ID, get_parent_map_id)


def event_duration(row):
    if not isinstance(row, dict):
        return None
    start = row.get("startTime")
    end = row.get("endTime")
    if not is_finite_number(start) or not is_finite_number(end):
        return None
    length = end - start
    if length <= 0:
        return None
    return length


def is_valid_scheduler_row(row):
    return event_duration(row) is not None


def row_matches_location(row, location):
    if not is_valid_scheduler_row(row) or not isinstance(location, dict):
        return False
    row_poi = row.get("areaPoiID")
    row_event = row.get("eventID")
    expected_poi = location.get("areaPoiID")
    expected_event = location.get("eventID")
    if row_poi is not None:
        if row_poi != expected_poi:
            return False
        if row_event is not None and expected_event is not None and row_event != expected_event:
            return False
        return True
    if row_event is not None and expected_event is not None and row_event == expected_event:
        return True
    if row_event in POI_BY_EVENT_ID and POI_BY_EVENT_ID[row_event] == expected_poi:
        return True
    return False


def deduplicate_rows(rows):
    result = []
    seen = set()
    for row in rows or []:
        if not is_valid_scheduler_row(row):
            continue
        key = (
            row.get("areaPoiID"),
            row.get("eventID"),
            row.get("startTime"),
            row.get("endTime"),
        )
        if key in seen:
            continue
        seen.add(key)
        result.append(row)
    return result


def sort_rows_by_start_time(rows):
    return sorted(
        list(rows or []),
        key=lambda row: (row.get("startTime") or 0, row.get("endTime") or 0),
    )


def filter_rows_for_location(rows, location):
    matched = [row for row in rows or [] if row_matches_location(row, location)]
    return sort_rows_by_start_time(deduplicate_rows(matched))


def filter_known_scheduler_rows(rows):
    matched = []
    for row in rows or []:
        if not is_valid_scheduler_row(row):
            continue
        poi = row.get("areaPoiID")
        event_id = row.get("eventID")
        if poi not in LOCATIONS_BY_POI and event_id not in POI_BY_EVENT_ID:
            continue
        if poi is not None and event_id is not None:
            expected = POI_BY_EVENT_ID.get(event_id)
            if expected != poi:
                continue
        matched.append(row)
    return sort_rows_by_start_time(deduplicate_rows(matched))


def is_occurrence_active(row, now):
    if not is_valid_scheduler_row(row) or not is_finite_number(now):
        return False
    return row["startTime"] <= now < row["endTime"]


def select_active_occurrence(rows, now):
    for row in rows or []:
        if is_occurrence_active(row, now):
            return row
    return None


def select_next_occurrence(rows, now):
    best = None
    for row in rows or []:
        start = row.get("startTime")
        if is_finite_number(start) and start > now:
            if best is None or start < best["startTime"]:
                best = row
    return best


def select_previous_occurrence(rows, now):
    best = None
    for row in rows or []:
        end = row.get("endTime")
        if is_finite_number(end) and end <= now:
            if best is None or end > best["endTime"]:
                best = row
    return best


def measured_start_interval(rows):
    best = None
    rows = list(rows or [])
    for index in range(1, len(rows)):
        previous_start = rows[index - 1].get("startTime")
        current_start = rows[index].get("startTime")
        if is_finite_number(previous_start) and is_finite_number(current_start) and current_start > previous_start:
            interval = current_start - previous_start
            if best is None or interval < best:
                best = interval
    return best


def representative_event_length(rows, next_occurrence):
    length = event_duration(next_occurrence)
    if length:
        return length
    for row in rows or []:
        length = event_duration(row)
        if length:
            return length
    return None


def resolve_previous_end_time(rows, next_occurrence, now):
    previous = select_previous_occurrence(rows, now)
    if previous and is_finite_number(previous.get("endTime")):
        return previous["endTime"], "scheduler"

    next_start = next_occurrence.get("startTime") if next_occurrence else None
    if not is_finite_number(next_start):
        return None, None

    prior = None
    for row in rows or []:
        start = row.get("startTime")
        if is_finite_number(start) and start < next_start:
            prior = row
    if prior and is_finite_number(prior.get("endTime")):
        return prior["endTime"], "scheduler"

    event_length = representative_event_length(rows, next_occurrence)
    start_interval = measured_start_interval(rows)
    if is_finite_number(start_interval) and is_finite_number(event_length) and start_interval > event_length:
        return next_start - (start_interval - event_length), "inferred"

    if is_finite_number(event_length) and SAME_LOCATION_RECURRENCE_SECONDS > event_length:
        return next_start - (SAME_LOCATION_RECURRENCE_SECONDS - event_length), "recurrence"

    return None, None


def inactive_ring_progress(previous_end_time, next_start_time, now):
    if not all(is_finite_number(value) for value in (previous_end_time, next_start_time, now)):
        return None
    span = next_start_time - previous_end_time
    if span <= 0:
        return None
    return clamp01((next_start_time - now) / span)


def active_ring_progress():
    return 1


def format_duration(seconds):
    if not is_finite_number(seconds):
        seconds = 0
    seconds = max(0, math.floor(seconds))
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    remain = seconds % 60
    if hours > 0:
        return f"{hours}:{minutes:02d}:{remain:02d}"
    return f"{minutes:02d}:{remain:02d}"


def resolve_location_state(location, rows, now, schedule_status, extras=None):
    extras = extras or {}
    state = {
        "eventID": location.get("eventID"),
        "areaPoiID": location.get("areaPoiID"),
        "fixedX": location.get("x"),
        "fixedY": location.get("y"),
        "liveX": extras.get("liveX"),
        "liveY": extras.get("liveY"),
        "status": "unavailable",
        "active": False,
        "ringVisible": False,
        "ringProgress": None,
        "ringMode": None,
        "countdownSeconds": None,
        "rowCount": 0,
        "previousEndTime": None,
        "previousEndSource": None,
        "previous": None,
        "activeOccurrence": None,
        "next": None,
    }
    x, y, source = resolve_coordinates(
        state["fixedX"], state["fixedY"], extras.get("liveX"), extras.get("liveY")
    )
    state["x"] = x
    state["y"] = y
    state["coordinateSource"] = source
    filtered = filter_rows_for_location(rows, location)
    state["rowCount"] = len(filtered)
    atlas, atlas_source = resolve_atlas(
        extras.get("schedulerAtlas"), extras.get("poiAtlas"), FALLBACK_ATLAS
    )
    state["atlas"] = atlas
    state["atlasSource"] = atlas_source
    state["name"] = extras.get("name") or extras.get("fallbackName")

    if schedule_status == "loading":
        state["status"] = "loading"
        return state
    if not is_finite_number(now):
        state["status"] = "unavailable"
        return state

    active = select_active_occurrence(filtered, now)
    nxt = select_next_occurrence(filtered, now)
    prev = select_previous_occurrence(filtered, now)
    state["activeOccurrence"] = active
    state["next"] = nxt
    state["previous"] = prev

    if active:
        state["status"] = "active"
        state["active"] = True
        state["ringVisible"] = True
        state["ringMode"] = "active"
        state["ringProgress"] = active_ring_progress()
        if is_finite_number(active.get("endTime")) and active["endTime"] > now:
            state["countdownSeconds"] = active["endTime"] - now
        return state

    if nxt:
        state["status"] = "inactive"
        previous_end, previous_source = resolve_previous_end_time(filtered, nxt, now)
        state["previousEndTime"] = previous_end
        state["previousEndSource"] = previous_source
        if is_finite_number(nxt.get("startTime")) and nxt["startTime"] > now:
            state["countdownSeconds"] = nxt["startTime"] - now
        progress = inactive_ring_progress(previous_end, nxt.get("startTime"), now)
        if progress is not None:
            state["ringVisible"] = True
            state["ringMode"] = "inactive"
            state["ringProgress"] = progress
        return state

    state["status"] = "unavailable"
    return state


def should_process_scheduler(in_zone):
    return in_zone is True


def should_show_pins(in_zone, displayed_map_id):
    return in_zone is True and displayed_map_id == COILED_ISLE_MAP_ID


def should_run_boundary_timer(in_zone, map_visible, displayed_map_id):
    return should_show_pins(in_zone, displayed_map_id) and map_visible is True


def should_run_tooltip_ticker(in_zone, map_visible, displayed_map_id, hovering):
    return should_show_pins(in_zone, displayed_map_id) and map_visible is True and hovering is True


def lua_constants_text() -> str:
    return CONSTANTS_LUA.read_text(encoding="utf-8")


def parse_lua_number(name: str) -> int:
    match = re.search(rf"{re.escape(name)}\s*=\s*(-?\d+)", lua_constants_text())
    if not match:
        raise AssertionError(f"missing Lua constant {name}")
    return int(match.group(1))


def parse_lua_string(name: str) -> str:
    match = re.search(rf'{re.escape(name)}\s*=\s*"([^"]+)"', lua_constants_text())
    if not match:
        raise AssertionError(f"missing Lua string constant {name}")
    return match.group(1)
