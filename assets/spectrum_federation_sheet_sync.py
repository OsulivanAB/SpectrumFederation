#!/usr/bin/env python3
"""Continuously sync SpectrumFederation SavedVariables data to Google Sheets."""

from __future__ import annotations

import argparse
import json
import logging
import os
import platform
import random
import sys
import time
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Any
from urllib import error, request


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG_NAME = "spectrum_federation_sheet_sync.json"
SAVED_VARIABLES_FILENAME = "SpectrumFederation.lua"
PAYLOAD_VERSION = 1

WOW_CLASS_RGB = {
    "WARRIOR": (0.78, 0.61, 0.43),
    "PALADIN": (0.96, 0.55, 0.73),
    "HUNTER": (0.67, 0.83, 0.45),
    "ROGUE": (1.00, 0.96, 0.41),
    "PRIEST": (1.00, 1.00, 1.00),
    "DEATHKNIGHT": (0.77, 0.12, 0.23),
    "SHAMAN": (0.00, 0.44, 0.87),
    "MAGE": (0.25, 0.78, 0.92),
    "WARLOCK": (0.53, 0.53, 0.93),
    "MONK": (0.00, 1.00, 0.59),
    "DRUID": (1.00, 0.49, 0.04),
    "DEMONHUNTER": (0.64, 0.19, 0.79),
    "EVOKER": (0.20, 0.58, 0.50),
}

DEFAULT_CLASS_COLOR = "#FFFFFF"
ROW_STRIPE_ODD = "#efefef"
ROW_STRIPE_EVEN = "#FFFFFF"

SHEET_COLUMNS = [
    "Helm",
    "Neck",
    "Shoulder",
    "Back",
    "Chest",
    "Wrist",
    "Main Hand",
    "Off Hand",
    "2H-Weapon",
    "Gloves",
    "Belt",
    "Pants",
    "Shoes",
    "Ring",
    "Trinket",
]

SLOT_TO_COLUMN = {
    "Helm": "Head",
    "Neck": "Neck",
    "Shoulder": "Shoulder",
    "Back": "Back",
    "Chest": "Chest",
    "Wrist": "Bracers",
    "Main Hand": "Weapon",
    "Off Hand": "OffHand",
    "2H-Weapon": "Weapon",
    "Gloves": "Hands",
    "Belt": "Belt",
    "Pants": "Pants",
    "Shoes": "Boots",
}

ENV_PREFIX = "SF_SHEET_SYNC_"


class ConfigError(RuntimeError):
    """Raised when the utility configuration is incomplete or invalid."""


class LuaParseError(RuntimeError):
    """Raised when the SavedVariables file cannot be parsed."""


def rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    return "#%02X%02X%02X" % tuple(max(0, min(255, round(channel * 255))) for channel in rgb)


CLASS_COLORS = {name: rgb_to_hex(rgb) for name, rgb in WOW_CLASS_RGB.items()}


@dataclass(frozen=True)
class Settings:
    endpoint_url: str
    shared_secret: str
    saved_variables_path: Path | None
    poll_interval_seconds: float
    debounce_seconds: float
    http_timeout_seconds: float
    retry_attempts: int
    once: bool


@dataclass(frozen=True)
class RuntimeState:
    path: Path | None
    path_source: str


@dataclass(frozen=True)
class FileSignature:
    mtime_ns: int
    size: int


class LuaTokenizer:
    """Tokenize the subset of Lua used by WoW SavedVariables files."""

    def __init__(self, text: str):
        self.text = text
        self.length = len(text)
        self.position = 0

    def next_token(self) -> tuple[str, Any]:
        self._skip_ignored()
        if self.position >= self.length:
            return ("EOF", None)

        char = self.text[self.position]
        single_char_tokens = {
            "{": "LBRACE",
            "}": "RBRACE",
            "[": "LBRACKET",
            "]": "RBRACKET",
            "=": "EQUALS",
            ",": "COMMA",
            ";": "SEMICOLON",
        }
        if char in single_char_tokens:
            self.position += 1
            return (single_char_tokens[char], char)
        if char == '"':
            return ("STRING", self._read_string())
        if char == "-" or char.isdigit():
            return ("NUMBER", self._read_number())
        if char == "_" or char.isalpha():
            return ("IDENT", self._read_identifier())
        raise LuaParseError(f"Unexpected character {char!r} at offset {self.position}")

    def _skip_ignored(self) -> None:
        while self.position < self.length:
            char = self.text[self.position]
            if char.isspace():
                self.position += 1
                continue
            if self.text.startswith("--", self.position):
                if self.text.startswith("--[[", self.position):
                    end = self.text.find("]]", self.position + 4)
                    self.position = self.length if end == -1 else end + 2
                else:
                    end = self.text.find("\n", self.position)
                    self.position = self.length if end == -1 else end + 1
                continue
            break

    def _read_string(self) -> str:
        self.position += 1
        buffer: list[str] = []
        while self.position < self.length:
            char = self.text[self.position]
            self.position += 1
            if char == '"':
                return "".join(buffer)
            if char == "\\":
                if self.position >= self.length:
                    raise LuaParseError("Unterminated escape sequence in string literal")
                escaped = self.text[self.position]
                self.position += 1
                mapping = {
                    '"': '"',
                    "\\": "\\",
                    "/": "/",
                    "b": "\b",
                    "f": "\f",
                    "n": "\n",
                    "r": "\r",
                    "t": "\t",
                }
                buffer.append(mapping.get(escaped, escaped))
                continue
            buffer.append(char)
        raise LuaParseError("Unterminated string literal")

    def _read_number(self) -> int | float:
        start = self.position
        if self.text[self.position] == "-":
            self.position += 1
        while self.position < self.length and self.text[self.position].isdigit():
            self.position += 1
        if self.position < self.length and self.text[self.position] == ".":
            self.position += 1
            while self.position < self.length and self.text[self.position].isdigit():
                self.position += 1
        if self.position < self.length and self.text[self.position] in "eE":
            self.position += 1
            if self.position < self.length and self.text[self.position] in "+-":
                self.position += 1
            while self.position < self.length and self.text[self.position].isdigit():
                self.position += 1
        raw = self.text[start:self.position]
        return float(raw) if any(char in raw for char in ".eE") else int(raw)

    def _read_identifier(self) -> str:
        start = self.position
        self.position += 1
        while self.position < self.length:
            char = self.text[self.position]
            if not (char == "_" or char.isalnum()):
                break
            self.position += 1
        return self.text[start:self.position]


class LuaParser:
    """Parse a SavedVariables Lua file into Python data structures."""

    def __init__(self, text: str):
        self.tokenizer = LuaTokenizer(text)
        self.current = self.tokenizer.next_token()
        self.next = self.tokenizer.next_token()

    def parse(self) -> dict[str, Any]:
        assignments: dict[str, Any] = {}
        while self.current[0] != "EOF":
            name = self._expect("IDENT")
            self._consume("EQUALS")
            assignments[name] = self._parse_value()
            if self.current[0] in {"COMMA", "SEMICOLON"}:
                self._advance()
        return assignments

    def _parse_value(self) -> Any:
        token_type, token_value = self.current
        if token_type == "STRING":
            self._advance()
            return token_value
        if token_type == "NUMBER":
            self._advance()
            return token_value
        if token_type == "IDENT":
            self._advance()
            if token_value == "true":
                return True
            if token_value == "false":
                return False
            if token_value == "nil":
                return None
            raise LuaParseError(f"Unexpected bare identifier value: {token_value}")
        if token_type == "LBRACE":
            return self._parse_table()
        raise LuaParseError(f"Unexpected token {token_type} while parsing value")

    def _parse_table(self) -> Any:
        self._consume("LBRACE")
        entries: list[tuple[Any, Any, bool]] = []
        implicit_index = 1
        has_explicit = False
        has_implicit = False

        while self.current[0] != "RBRACE":
            if self.current[0] in {"COMMA", "SEMICOLON"}:
                self._advance()
                continue

            if self.current[0] == "LBRACKET":
                self._advance()
                key = self._parse_value()
                self._consume("RBRACKET")
                self._consume("EQUALS")
                value = self._parse_value()
                entries.append((key, value, True))
                has_explicit = True
            elif self.current[0] == "IDENT" and self.next[0] == "EQUALS":
                key = self.current[1]
                self._advance()
                self._consume("EQUALS")
                value = self._parse_value()
                entries.append((key, value, True))
                has_explicit = True
            else:
                value = self._parse_value()
                entries.append((implicit_index, value, False))
                implicit_index += 1
                has_implicit = True

            if self.current[0] in {"COMMA", "SEMICOLON"}:
                self._advance()

        self._consume("RBRACE")

        if has_implicit and not has_explicit:
            return [value for _, value, _ in entries]

        mapped: dict[Any, Any] = {}
        for key, value, _ in entries:
            mapped[key] = value
        return mapped

    def _expect(self, token_type: str) -> Any:
        if self.current[0] != token_type:
            raise LuaParseError(f"Expected {token_type}, found {self.current[0]}")
        value = self.current[1]
        self._advance()
        return value

    def _consume(self, token_type: str) -> None:
        if self.current[0] != token_type:
            raise LuaParseError(f"Expected {token_type}, found {self.current[0]}")
        self._advance()

    def _advance(self) -> None:
        self.current = self.next
        self.next = self.tokenizer.next_token()


def parse_saved_variables_text(text: str) -> dict[str, Any]:
    parser = LuaParser(text.lstrip("\ufeff"))
    assignments = parser.parse()
    database = assignments.get("SpectrumFederationDB")
    if not isinstance(database, dict):
        raise LuaParseError("SpectrumFederationDB was not found in the SavedVariables file")
    return database


def parse_saved_variables_file(path: Path) -> dict[str, Any]:
    return parse_saved_variables_text(path.read_text(encoding="utf-8"))


def iter_profiles(profiles: Any) -> list[dict[str, Any]]:
    if isinstance(profiles, list):
        return [profile for profile in profiles if isinstance(profile, dict)]
    if isinstance(profiles, dict):
        return [profile for profile in profiles.values() if isinstance(profile, dict)]
    return []


def get_profile_by_id(profiles: Any, profile_id: str | None) -> dict[str, Any] | None:
    if not profile_id:
        return None
    if isinstance(profiles, dict):
        profile = profiles.get(profile_id)
        return profile if isinstance(profile, dict) else None
    for profile in iter_profiles(profiles):
        if profile.get("_profileId") == profile_id:
            return profile
    return None


def resolve_active_profile(database: dict[str, Any]) -> dict[str, Any]:
    loot_helper = database.get("lootHelper")
    if not isinstance(loot_helper, dict):
        raise ConfigError("SpectrumFederationDB.lootHelper is missing or invalid")

    profiles = loot_helper.get("profiles")
    profile = get_profile_by_id(profiles, loot_helper.get("activeProfileId"))
    if profile:
        return profile

    active_pointer = loot_helper.get("activeProfile")
    if isinstance(active_pointer, dict):
        return active_pointer

    for candidate in iter_profiles(profiles):
        if candidate.get("_activeProfile") is True:
            return candidate

    raise ConfigError("No active loot profile could be found in SpectrumFederationDB.lootHelper")


def split_identifier(identifier: str) -> tuple[str, str]:
    if "-" not in identifier:
        return identifier, ""
    name, realm = identifier.split("-", 1)
    return name, realm


def normalize_class_token(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    normalized = "".join(character for character in value.upper() if character.isalnum())
    return normalized or None


def gear_status(used: Any) -> str:
    return "❌" if bool(used) else "✅"


def build_row(member: dict[str, Any]) -> dict[str, Any]:
    identifier = str(member.get("identifier") or "")
    fallback_name, realm = split_identifier(identifier)
    armor = member.get("armor") if isinstance(member.get("armor"), dict) else {}
    class_token = normalize_class_token(member.get("class") or member.get("className"))
    player_name = str(member.get("name") or member.get("member_name") or fallback_name)

    gear = {
        "Helm": gear_status(armor.get("Head")),
        "Neck": gear_status(armor.get("Neck")),
        "Shoulder": gear_status(armor.get("Shoulder")),
        "Back": gear_status(armor.get("Back")),
        "Chest": gear_status(armor.get("Chest")),
        "Wrist": gear_status(armor.get("Bracers")),
        "Main Hand": gear_status(armor.get("Weapon")),
        "Off Hand": gear_status(armor.get("OffHand")),
        "2H-Weapon": gear_status(armor.get("Weapon")),
        "Gloves": gear_status(armor.get("Hands")),
        "Belt": gear_status(armor.get("Belt")),
        "Pants": gear_status(armor.get("Pants")),
        "Shoes": gear_status(armor.get("Boots")),
        "Ring": f"{gear_status(armor.get('Ring1'))} {gear_status(armor.get('Ring2'))}",
        "Trinket": f"{gear_status(armor.get('Trinket1'))} {gear_status(armor.get('Trinket2'))}",
    }

    point_balance = member.get("pointBalance", 0)
    if not isinstance(point_balance, (int, float)):
        point_balance = 0

    cells = [player_name, point_balance]
    cells.extend(gear[column] for column in SHEET_COLUMNS)

    return {
        "playerName": player_name,
        "identifier": identifier,
        "realm": str(member.get("member_realm") or realm),
        "classToken": class_token,
        "classColor": CLASS_COLORS.get(class_token or "", DEFAULT_CLASS_COLOR),
        "points": point_balance,
        "gear": gear,
        "cells": cells,
    }


def build_payload(database: dict[str, Any], source_path: Path) -> dict[str, Any]:
    profile = resolve_active_profile(database)
    point_name = str(profile.get("_pointName") or "Points")
    members = profile.get("_members") if isinstance(profile.get("_members"), list) else []
    rows = [build_row(member) for member in members if isinstance(member, dict)]
    rows.sort(key=lambda row: (row["playerName"].casefold(), row["identifier"].casefold()))
    headers = ["Player Name", point_name]
    headers.extend(SHEET_COLUMNS)

    return {
        "version": PAYLOAD_VERSION,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sourcePath": str(source_path),
        "profile": {
            "id": str(profile.get("_profileId") or ""),
            "name": str(profile.get("_profileName") or ""),
            "pointName": point_name,
            "memberCount": len(rows),
        },
        "headers": headers,
        "rows": rows,
    }


def load_json_config(config_path: Path | None) -> tuple[dict[str, Any], Path | None]:
    candidates: list[Path] = []
    if config_path is not None:
        candidates.append(config_path.expanduser())
    else:
        script_local = SCRIPT_DIR / DEFAULT_CONFIG_NAME
        cwd_local = Path.cwd() / DEFAULT_CONFIG_NAME
        candidates.append(script_local)
        if cwd_local != script_local:
            candidates.append(cwd_local)

    for candidate in candidates:
        if candidate.exists():
            data = json.loads(candidate.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ConfigError(f"Config file {candidate} must contain a JSON object")
            return data, candidate.resolve()
    return {}, None


def env_value(name: str) -> str | None:
    value = os.environ.get(f"{ENV_PREFIX}{name}")
    if value is None or value == "":
        return None
    return value


def get_setting_value(
    cli_value: Any,
    env_name: str,
    config_data: dict[str, Any],
    config_key: str,
    default: Any = None,
) -> Any:
    if cli_value not in (None, ""):
        return cli_value
    env_setting = env_value(env_name)
    if env_setting not in (None, ""):
        return env_setting
    if config_key in config_data and config_data[config_key] not in (None, ""):
        return config_data[config_key]
    return default


def resolve_configured_path(path_value: Any, config_path: Path | None) -> Path | None:
    if path_value in (None, ""):
        return None
    path = Path(str(path_value)).expanduser()
    if not path.is_absolute() and config_path is not None:
        path = (config_path.parent / path).resolve()
    return path


def build_settings(args: argparse.Namespace) -> Settings:
    config_data, config_path = load_json_config(args.config)

    endpoint_url = get_setting_value(args.endpoint_url, "ENDPOINT_URL", config_data, "endpoint_url")
    shared_secret = get_setting_value(args.shared_secret, "SHARED_SECRET", config_data, "shared_secret")
    saved_variables_path = resolve_configured_path(
        get_setting_value(args.saved_variables_path, "SAVED_VARIABLES_PATH", config_data, "saved_variables_path"),
        config_path,
    )
    poll_interval_seconds = float(
        get_setting_value(args.poll_interval_seconds, "POLL_INTERVAL_SECONDS", config_data, "poll_interval_seconds", 1.0)
    )
    debounce_seconds = float(
        get_setting_value(args.debounce_seconds, "DEBOUNCE_SECONDS", config_data, "debounce_seconds", 1.5)
    )
    http_timeout_seconds = float(
        get_setting_value(args.http_timeout_seconds, "HTTP_TIMEOUT_SECONDS", config_data, "http_timeout_seconds", 30.0)
    )
    retry_attempts = int(get_setting_value(args.retry_attempts, "RETRY_ATTEMPTS", config_data, "retry_attempts", 3))

    if not endpoint_url:
        raise ConfigError("An Apps Script endpoint URL is required. Set it in the config file or use --endpoint-url.")
    if not shared_secret:
        raise ConfigError("A shared secret is required. Set it in the config file or use --shared-secret.")
    if poll_interval_seconds <= 0:
        raise ConfigError("poll_interval_seconds must be greater than zero")
    if debounce_seconds < 0:
        raise ConfigError("debounce_seconds cannot be negative")
    if http_timeout_seconds <= 0:
        raise ConfigError("http_timeout_seconds must be greater than zero")
    if retry_attempts < 1:
        raise ConfigError("retry_attempts must be at least 1")

    return Settings(
        endpoint_url=str(endpoint_url),
        shared_secret=str(shared_secret),
        saved_variables_path=saved_variables_path,
        poll_interval_seconds=poll_interval_seconds,
        debounce_seconds=debounce_seconds,
        http_timeout_seconds=http_timeout_seconds,
        retry_attempts=retry_attempts,
        once=args.once,
    )


def discover_saved_variables_candidates() -> list[Path]:
    system = platform.system()
    roots: list[Path] = []

    if system == "Windows":
        for env_name in ("PROGRAMFILES(X86)", "PROGRAMFILES"):
            value = os.environ.get(env_name)
            if value:
                roots.append(Path(value) / "World of Warcraft")
        roots.extend(
            [
                Path.home() / "Games" / "World of Warcraft",
                Path("C:/Games/World of Warcraft"),
                Path("D:/Games/World of Warcraft"),
                Path("E:/Games/World of Warcraft"),
            ]
        )
    elif system == "Darwin":
        roots.extend(
            [
                Path("/Applications/World of Warcraft"),
                Path.home() / "Applications" / "World of Warcraft",
                Path.home() / "Games" / "World of Warcraft",
            ]
        )
    else:
        roots.extend(
            [
                Path.home() / "Games" / "World of Warcraft",
                Path.home() / ".wine" / "drive_c" / "Program Files (x86)" / "World of Warcraft",
            ]
        )

    patterns = [
        "_retail_/WTF/Account/*/SavedVariables/SpectrumFederation.lua",
        "_beta_/WTF/Account/*/SavedVariables/SpectrumFederation.lua",
        "_ptr_/WTF/Account/*/SavedVariables/SpectrumFederation.lua",
    ]

    unique: dict[str, Path] = {}
    for root in roots:
        if not root.exists():
            continue
        for pattern in patterns:
            for candidate in root.glob(pattern):
                if candidate.is_file():
                    unique[str(candidate.resolve())] = candidate.resolve()

    return sorted(unique.values(), key=lambda item: item.stat().st_mtime_ns, reverse=True)


def resolve_runtime_state(settings: Settings, current_state: RuntimeState | None = None) -> RuntimeState:
    if settings.saved_variables_path is not None:
        return RuntimeState(settings.saved_variables_path, "configured path")

    candidates = discover_saved_variables_candidates()
    if not candidates:
        return RuntimeState(None, "auto-discovery")

    selected = candidates[0]
    if current_state and current_state.path == selected:
        return current_state

    if len(candidates) > 1:
        logging.info("Auto-discovery found %d SavedVariables files. Using the most recently updated: %s", len(candidates), selected)
    else:
        logging.info("Auto-discovery selected SavedVariables file: %s", selected)
    return RuntimeState(selected, "auto-discovery")


def read_signature(path: Path) -> FileSignature:
    stat_result = path.stat()
    return FileSignature(stat_result.st_mtime_ns, stat_result.st_size)


def payload_digest(payload: dict[str, Any]) -> str:
    serialized = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256(serialized.encode("utf-8")).hexdigest()


def post_payload(settings: Settings, payload: dict[str, Any]) -> str:
    envelope = {
        "secret": settings.shared_secret,
        "payload": payload,
    }
    data = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    headers = {
        "Content-Type": "application/json; charset=utf-8",
        "User-Agent": "SpectrumFederationSheetSync/1.0",
    }
    request_object = request.Request(settings.endpoint_url, data=data, headers=headers, method="POST")

    for attempt in range(1, settings.retry_attempts + 1):
        try:
            with request.urlopen(request_object, timeout=settings.http_timeout_seconds) as response:
                return response.read().decode("utf-8", errors="replace")
        except error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            if 400 <= exc.code < 500:
                raise RuntimeError(f"Apps Script returned HTTP {exc.code}: {body or exc.reason}") from exc
            should_retry = attempt < settings.retry_attempts
            logging.warning(
                "HTTP %s from Apps Script on attempt %d/%d%s",
                exc.code,
                attempt,
                settings.retry_attempts,
                "; retrying" if should_retry else "",
            )
            if not should_retry:
                raise RuntimeError(f"Apps Script returned HTTP {exc.code}: {body or exc.reason}") from exc
        except error.URLError as exc:
            should_retry = attempt < settings.retry_attempts
            logging.warning(
                "Network error on attempt %d/%d: %s%s",
                attempt,
                settings.retry_attempts,
                exc.reason,
                "; retrying" if should_retry else "",
            )
            if not should_retry:
                raise RuntimeError(f"Unable to reach Apps Script endpoint: {exc.reason}") from exc

        sleep_seconds = min(8.0, (2 ** (attempt - 1)) + random.uniform(0.0, 0.5))
        time.sleep(sleep_seconds)

    raise RuntimeError("Exhausted all retry attempts")


def sync_once(settings: Settings, state: RuntimeState) -> tuple[str, str]:
    if state.path is None:
        raise FileNotFoundError(
            "SpectrumFederation.lua could not be auto-discovered. Configure --saved-variables-path or update the JSON config."
        )
    if not state.path.exists():
        raise FileNotFoundError(f"SavedVariables file not found: {state.path}")

    database = parse_saved_variables_file(state.path)
    payload = build_payload(database, state.path)
    response = post_payload(settings, payload)
    return payload_digest(payload), response


def watch(settings: Settings) -> int:
    runtime_state = resolve_runtime_state(settings)
    last_signature: FileSignature | None = None
    last_payload_hash: str | None = None
    pending_deadline = time.monotonic()
    missing_logged = False

    while True:
        runtime_state = resolve_runtime_state(settings, runtime_state)
        current_path = runtime_state.path

        if current_path is None or not current_path.exists():
            if not missing_logged:
                if current_path is None:
                    logging.warning(
                        "Could not find %s via %s. Waiting for the file or use --saved-variables-path.",
                        SAVED_VARIABLES_FILENAME,
                        runtime_state.path_source,
                    )
                else:
                    logging.warning("Waiting for SavedVariables file to appear: %s", current_path)
                missing_logged = True
            if settings.once:
                return 1
            time.sleep(settings.poll_interval_seconds)
            continue

        if missing_logged:
            logging.info("Found SavedVariables file: %s", current_path)
            missing_logged = False
            pending_deadline = time.monotonic()

        signature = read_signature(current_path)
        if last_signature is None:
            last_signature = signature
            pending_deadline = time.monotonic()
        elif signature != last_signature:
            last_signature = signature
            pending_deadline = time.monotonic() + settings.debounce_seconds
            logging.info("Detected update to %s; waiting %.1fs before syncing", current_path, settings.debounce_seconds)

        now = time.monotonic()
        if pending_deadline is not None and now >= pending_deadline:
            try:
                database = parse_saved_variables_file(current_path)
                payload = build_payload(database, current_path)
                current_hash = payload_digest(payload)

                if current_hash == last_payload_hash:
                    logging.info("SavedVariables changed but the normalized payload is unchanged; skipping upload")
                else:
                    response = post_payload(settings, payload)
                    last_payload_hash = current_hash
                    logging.info(
                        "Synced %d members from profile '%s' to Google Sheets",
                        payload["profile"]["memberCount"],
                        payload["profile"]["name"],
                    )
                    if response:
                        logging.debug("Apps Script response: %s", response)
                pending_deadline = None
                if settings.once:
                    return 0
            except (ConfigError, FileNotFoundError, LuaParseError, RuntimeError, ValueError) as exc:
                logging.error("Sync failed: %s", exc)
                if settings.once:
                    return 1
                pending_deadline = time.monotonic() + max(settings.debounce_seconds, 5.0)

        time.sleep(settings.poll_interval_seconds)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Watch SpectrumFederation.lua and sync the active profile to a Google Sheet via Apps Script."
    )
    parser.add_argument("--config", type=Path, help=f"Path to a JSON config file. Defaults to {DEFAULT_CONFIG_NAME} next to the script.")
    parser.add_argument("--endpoint-url", help="Google Apps Script web app URL.")
    parser.add_argument("--shared-secret", help="Shared secret that must match the Apps Script configuration.")
    parser.add_argument("--saved-variables-path", help="Explicit path to SpectrumFederation.lua. Use this if auto-discovery is not correct.")
    parser.add_argument("--poll-interval-seconds", type=float, help="How often to check the file for changes. Default: 1.0")
    parser.add_argument("--debounce-seconds", type=float, help="How long to wait after a file change before syncing. Default: 1.5")
    parser.add_argument("--http-timeout-seconds", type=float, help="HTTP timeout for Apps Script requests. Default: 30")
    parser.add_argument("--retry-attempts", type=int, help="How many times to retry a failed HTTP request. Default: 3")
    parser.add_argument("--once", action="store_true", help="Run one sync attempt and then exit.")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose logging.")
    return parser.parse_args(argv)


def configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    configure_logging(args.verbose)

    try:
        settings = build_settings(args)
    except (ConfigError, ValueError, json.JSONDecodeError) as exc:
        logging.error("Configuration error: %s", exc)
        return 2

    if settings.saved_variables_path is not None:
        logging.info("Watching configured SavedVariables file: %s", settings.saved_variables_path)
    else:
        logging.info("Watching for %s via auto-discovery on %s", SAVED_VARIABLES_FILENAME, platform.system())

    logging.info("Apps Script endpoint: %s", settings.endpoint_url)
    logging.info(
        "Polling every %.1fs with a %.1fs debounce. Press Ctrl+C to stop.",
        settings.poll_interval_seconds,
        settings.debounce_seconds,
    )

    try:
        return watch(settings)
    except KeyboardInterrupt:
        logging.info("Stopping sync utility")
        return 0


if __name__ == "__main__":
    sys.exit(main())