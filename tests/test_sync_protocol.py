"""Run production Lua SyncProtocol warning-dedupe tests."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "sync_protocol_tests.lua"
SYNC_PROTOCOL = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "SyncProtocol.lua"
COMM = REPO_ROOT / "SpectrumFederation" / "modules" / "LootHelper" / "Comm.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production SyncProtocol tests")


def test_sync_protocol_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 SyncProtocol tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert SYNC_PROTOCOL.exists()


def test_parent_toc_loads_sync_protocol_before_comm():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    protocol = toc.find("modules/LootHelper/SyncProtocol.lua")
    comm = toc.find("modules/LootHelper/Comm.lua")
    assert 0 <= protocol < comm
    assert COMM.exists()
