"""Tests for TOC version-bump comparison used after packaged addon changes."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / ".github" / "scripts"


def _load_script(name):
    module_path = SCRIPTS_DIR / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


bump = _load_script("check_version_bump")


def git(repo, *args):
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )


def write_toc(repo, version):
    toc = repo / "SpectrumFederation" / "SpectrumFederation.toc"
    toc.parent.mkdir(parents=True, exist_ok=True)
    toc.write_text(f"## Interface: 120100\n## Version: {version}\n", encoding="utf-8")


def init_repo(tmp_path, version="1.5.2"):
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init", "-b", "main")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    write_toc(repo, version)
    git(repo, "add", ".")
    git(repo, "commit", "-m", "initial")
    git(repo, "checkout", "-b", "beta")
    return repo


def test_base_commit_rejects_forgotten_bump(tmp_path, monkeypatch, capsys):
    repo = init_repo(tmp_path, "1.5.2-beta.1")
    before = git(repo, "rev-parse", "HEAD").stdout.strip()
    git(repo, "commit", "--allow-empty", "-m", "feat: packaged lua without bump")
    monkeypatch.chdir(repo)
    with pytest.raises(SystemExit) as exc:
        bump.main(["beta", "--base-commit", before])
    captured = capsys.readouterr()
    assert exc.value.code == 1
    assert "must be ahead of the base" in captured.out


def test_base_commit_accepts_bumped_beta(tmp_path, monkeypatch, capsys):
    repo = init_repo(tmp_path, "1.5.2-beta.1")
    before = git(repo, "rev-parse", "HEAD").stdout.strip()
    write_toc(repo, "1.5.2-beta.2")
    git(repo, "add", "SpectrumFederation/SpectrumFederation.toc")
    git(repo, "commit", "-m", "chore: bump beta version")
    monkeypatch.chdir(repo)
    assert bump.main(["beta", "--base-commit", before]) == 0
    captured = capsys.readouterr()
    assert "Addon version has been bumped" in captured.out
