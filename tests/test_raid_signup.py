"""Run production Lua Raid Signup tests (#404)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PARENT_TOC = REPO_ROOT / "SpectrumFederation" / "SpectrumFederation.toc"
LUA_TESTS = REPO_ROOT / "tests" / "lua" / "raid_signup_tests.lua"
RS_DIR = REPO_ROOT / "SpectrumFederation" / "modules" / "RaidSignup"
PAGE = REPO_ROOT / "SpectrumFederation" / "modules" / "UI" / "Settings" / "Pages" / "RaidSignup.lua"
DOCS = REPO_ROOT / "docs" / "development" / "raid-signup" / "index.md"
LOCALE = REPO_ROOT / "SpectrumFederation" / "locale" / "enUS.lua"


def _lua51() -> str:
    path = shutil.which("lua5.1")
    if path:
        return path
    pytest.fail("lua5.1 is required to execute production Raid Signup tests")


def test_raid_signup_production_lua():
    result = subprocess.run(
        [_lua51(), str(LUA_TESTS)],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            "lua5.1 Raid Signup tests failed\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    assert "0 failed" in result.stdout
    assert RS_DIR.exists()
    assert PAGE.exists()
    assert DOCS.exists()


def test_parent_toc_loads_raid_signup_after_guild_info():
    toc = PARENT_TOC.read_text(encoding="utf-8")
    gi_gossip = toc.find("modules/GuildInfo/Gossip.lua")
    coverage = toc.find("modules/RaidSignup/Coverage.lua")
    state = toc.find("modules/RaidSignup/State.lua")
    authority = toc.find("modules/RaidSignup/Authority.lua")
    operations = toc.find("modules/RaidSignup/Operations.lua")
    gossip = toc.find("modules/RaidSignup/Gossip.lua")
    page = toc.find("modules/UI/Settings/Pages/RaidSignup.lua")
    assert 0 <= gi_gossip < coverage < state < authority < operations < gossip
    assert 0 <= page


def test_raid_signup_provider_isolated():
    gossip = (RS_DIR / "Gossip.lua").read_text(encoding="utf-8")
    state = (RS_DIR / "State.lua").read_text(encoding="utf-8")
    assert "sf.raidsignup.roster" in state or "sf.raidsignup.roster" in gossip
    assert "sf.guildsupplies.config" not in gossip
    assert "sf.guildinfo.relationships" not in gossip
    for path in RS_DIR.glob("*.lua"):
        text = path.read_text(encoding="utf-8")
        assert "SendAddonMessage" not in text
        assert "EnableSynthetic" not in text
        assert "PrintSuccess" not in text
        assert "SendChatMessage" not in text


def test_raid_signup_confirmed_coverage_names():
    coverage = (RS_DIR / "Coverage.lua").read_text(encoding="utf-8")
    locale = LOCALE.read_text(encoding="utf-8")
    assert "Atrophic Poison" in coverage
    assert "Blessing of the Bronze" in coverage
    assert "Boss DR" not in coverage
    assert 'L["RAID_SIGNUP_COV_ATROPHIC"]' in locale
    assert 'L["RAID_SIGNUP_COV_BRONZE"]' in locale
    assert "Atrophic Poison" in locale
    assert "Blessing of the Bronze" in locale


def test_raid_signup_docs_present():
    docs = DOCS.read_text(encoding="utf-8")
    assert "sf.raidsignup.roster" in docs
    assert "creatorGuid" in docs
    assert "relay_lacks_authority" in docs
