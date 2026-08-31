"""Tests for human-readable Interface badge formatting."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / ".github" / "scripts"


def _load_script(name):
    module_path = SCRIPTS_DIR / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


blizzard_api = _load_script("blizzard_api")
validate_docs = _load_script("validate_docs")


@pytest.mark.parametrize(
    ("raw", "display"),
    [
        ("120100", "12.1.0"),
        ("120001", "12.0.1"),
        ("110207", "11.2.7"),
        ("100000", "10.0.0"),
        (120100, "12.1.0"),
    ],
)
def test_interface_to_display_strips_leading_zeros(raw, display):
    assert blizzard_api.interface_to_display(raw) == display


def test_interface_to_display_round_trip_with_version_to_interface():
    assert blizzard_api.version_to_interface("12.1.0.64978") == "120100"
    assert blizzard_api.interface_to_display("120100") == "12.1.0"


@pytest.mark.parametrize("raw", ["12010", "12.1.0", "abc123", ""])
def test_interface_to_display_rejects_non_six_digit_values(raw):
    with pytest.raises(ValueError, match="6-digit"):
        blizzard_api.interface_to_display(raw)


def _write_badge_fixture(repo_root, *, interface, version, badge_interface):
    toc_dir = repo_root / "SpectrumFederation"
    toc_dir.mkdir()
    (toc_dir / "SpectrumFederation.toc").write_text(
        f"## Interface: {interface}\n## Version: {version}\n",
        encoding="utf-8",
    )
    (repo_root / "README.md").write_text(
        (
            "<!-- STATUS_BADGES_START -->\n"
            f"![Interface](https://img.shields.io/badge/Interface-{badge_interface}-00aaff)\n"
            "![Track](https://img.shields.io/badge/Track-Retail-ff8800)\n"
            f"![Addon Version](https://img.shields.io/badge/Version-{version}-brightgreen)\n"
            "<!-- STATUS_BADGES_END -->\n"
        ),
        encoding="utf-8",
    )


def test_validate_readme_badges_accepts_human_readable_interface(tmp_path):
    _write_badge_fixture(
        tmp_path,
        interface="120100",
        version="1.3.0",
        badge_interface="12.1.0",
    )

    assert validate_docs.validate_readme_badges(tmp_path) == []


def test_validate_readme_badges_rejects_raw_toc_interface_on_stable(tmp_path):
    _write_badge_fixture(
        tmp_path,
        interface="120100",
        version="1.3.0",
        badge_interface="120100",
    )

    errors = validate_docs.validate_readme_badges(tmp_path)
    assert errors
    assert "12.1.0" in errors[0]
