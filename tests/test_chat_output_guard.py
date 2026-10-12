"""Tests for the Spectrum player-facing chat-output baseline guard."""

from __future__ import annotations

import json
import textwrap
from pathlib import Path

import pytest

import importlib.util
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / ".github" / "scripts" / "check_chat_output.py"

_spec = importlib.util.spec_from_file_location("check_chat_output", SCRIPT)
assert _spec and _spec.loader
check_chat_output = importlib.util.module_from_spec(_spec)
sys.modules["check_chat_output"] = check_chat_output
_spec.loader.exec_module(check_chat_output)


@pytest.fixture()
def addon_tree(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    root = tmp_path / "SpectrumFederation"
    (root / "modules").mkdir(parents=True)
    monkeypatch.setattr(check_chat_output, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(
        check_chat_output,
        "ADDON_ROOTS",
        ("SpectrumFederation",),
    )
    return root


def _write(path: Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(contents).lstrip(), encoding="utf-8")


def test_scan_ignores_comments_strings_debug_and_libs(addon_tree: Path, tmp_path: Path):
    _write(
        addon_tree / "modules" / "Feature.lua",
        """
        local addonName, SF = ...
        -- SF:PrintError("commented")
        local s = "SF:PrintWarning('literal')"
        function Feature:Work()
            SF.Debug:Warn("CAT", "not chat")
            SF:PrintError("real error")
        end
        """,
    )
    _write(
        addon_tree / "Libs" / "Vendor.lua",
        """
        print("vendored")
        DEFAULT_CHAT_FRAME:AddMessage("vendored")
        """,
    )

    sites = check_chat_output.scan_repo()
    assert len(sites) == 1
    assert sites[0].kind == "PrintError"
    assert "real error" in sites[0].signature


def test_new_site_fails_until_baseline_updated(addon_tree: Path, tmp_path: Path):
    _write(
        addon_tree / "modules" / "Feature.lua",
        """
        function Feature:Work()
            SF:PrintInfo("hello")
        end
        """,
    )
    baseline = tmp_path / "baseline.json"
    check_chat_output.write_baseline(baseline, [])

    sites = check_chat_output.scan_repo()
    new_errors, hotpath_errors, removed = check_chat_output.compare(
        sites, check_chat_output.load_baseline(baseline)
    )
    assert new_errors
    assert not hotpath_errors

    check_chat_output.write_baseline(baseline, sites)
    new_errors, hotpath_errors, removed = check_chat_output.compare(
        sites, check_chat_output.load_baseline(baseline)
    )
    assert not new_errors
    assert not hotpath_errors
    assert not removed


def test_hotpath_move_requires_explicit_ok(addon_tree: Path, tmp_path: Path):
    _write(
        addon_tree / "modules" / "Feature.lua",
        """
        function Feature:OnUpdate()
            SF:PrintWarning("tick")
        end
        """,
    )
    sites = check_chat_output.scan_repo()
    assert sites and sites[0].hotpath

    baseline_path = tmp_path / "baseline.json"
    check_chat_output.write_baseline(baseline_path, sites)
    data = check_chat_output.load_baseline(baseline_path)
    assert data["sites"][0]["hotpath_ok"] is False

    _, hotpath_errors, _ = check_chat_output.compare(sites, data)
    assert hotpath_errors

    data["sites"][0]["hotpath_ok"] = True
    _, hotpath_errors, _ = check_chat_output.compare(sites, data)
    assert not hotpath_errors


def test_cli_passes_against_repo_baseline():
    # Integration smoke: current repository baseline must validate.
    assert check_chat_output.main([]) == 0
