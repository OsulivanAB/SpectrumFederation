"""
Update CHANGELOG.md for beta post-merge and Promote Beta to Main.

Called by:
- post-merge-beta.yml after addon changes land on beta
- promote-beta-to-main.yml after beta is merged to main

Deterministic logic owns versions, git ranges, changelog structure,
idempotency, and validation. AI is used only for semantic judgments
(user-facing vs internal, grouping, and wording) and must return
structured JSON that is validated before any file write.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CHANGELOG_PATH = Path("CHANGELOG.md")
TOC_PATH = Path("SpectrumFederation/SpectrumFederation.toc")
ADDON_PATHS = (
    "SpectrumFederation/",
    "SpectrumFederation_CursedSurgeTracker/",
)
INTERNAL_PATH_PREFIXES = (
    ".github/",
    "tests/",
    "docs/",
    ".cursor/",
    "site/",
)
INTERNAL_PATH_NAMES = {
    "CHANGELOG.md",
    "README.md",
    "AGENTS.md",
    "mkdocs.yml",
    "pkgmeta.yaml",
    "requirements-docs.txt",
}
AUTOMATION_MESSAGE_PREFIXES = (
    "docs: update changelog",
    "docs: update badges",
    "chore: update version to",
    "chore: update interface to",
    "chore: promote beta to main",
    "chore: promote non-addon",
)
INTERNAL_SUBJECT_PREFIXES = (
    "test:",
    "ci:",
    "chore:",
    "docs:",
    "style:",
    "refactor:",
    "build:",
)
SECTION_RE = re.compile(
    r"^## \[([^\]]+)\](?:\s+-\s+(\S+))?\s*$",
    re.MULTILINE,
)
PR_RE = re.compile(r"(?:Merge pull request #|#)(\d+)")
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$")
STABLE_TAG_RE = re.compile(r"^v(\d+\.\d+\.\d+)$")
PLACEHOLDER_RE = re.compile(
    r"infrastructure and tooling updates",
    re.IGNORECASE,
)
CATEGORIES = ("Added", "Changed", "Fixed", "Removed")
MAX_DIFF_CHARS = 24000
MAX_PROMPT_CHARS = 28000
MAX_ENTRY_CHARS = 400
MAX_ENTRIES = 12

FEATURE_CATALOG = (
    {
        "name": "Cursed Surge Tracker",
        "aliases": ("cursed surge", "cursed-surge", "coiled isle"),
        "paths": ("SpectrumFederation_CursedSurgeTracker/",),
    },
    {
        "name": "Version Check",
        "aliases": ("version check", "/sf version", "versioncheck"),
        "paths": (
            "SpectrumFederation/modules/VersionCheck.lua",
            "SpectrumFederation/modules/UI/VersionCheck/",
        ),
    },
    {
        "name": "Reward Pot",
        "aliases": ("reward pot", "reward-pot"),
        "paths": (
            "SpectrumFederation/modules/LootHelper/",
            "SpectrumFederation/modules/UI/LootHelper/",
        ),
    },
    {
        "name": "Loot Helper",
        "aliases": ("loot helper", "loothelper"),
        "paths": (
            "SpectrumFederation/modules/LootHelper/",
            "SpectrumFederation/modules/UI/LootHelper/",
        ),
    },
    {
        "name": "Raid Check",
        "aliases": ("raid check", "raidcheck"),
        "paths": ("SpectrumFederation/modules/RaidCheck.lua",),
    },
    {
        "name": "Sync Sessions",
        "aliases": ("sync session", "loothelpersync"),
        "paths": ("SpectrumFederation/modules/LootHelperSync/",),
    },
    {
        "name": "Loot Logs",
        "aliases": ("loot log", "lootlogs"),
        "paths": ("SpectrumFederation/modules/LootHelper/",),
    },
    {
        "name": "Settings",
        "aliases": ("settings ui", "settings"),
        "paths": (
            "SpectrumFederation/modules/Settings/",
            "SpectrumFederation/modules/UI/Settings/",
        ),
    },
)


class ChangelogError(RuntimeError):
    """Abort changelog generation without writing a guessed entry."""


def run_git(args, check=True):
    """Run a git command and return stdout text."""
    result = subprocess.run(
        ["git", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "git command failed"
        raise ChangelogError(f"git {' '.join(args)}: {message}")
    return result.stdout.strip() if result.returncode == 0 else ""


def read_toc_version(toc_text=None):
    """Return the TOC Version value."""
    text = TOC_PATH.read_text(encoding="utf-8") if toc_text is None else toc_text
    match = re.search(r"^## Version:\s*(.+)$", text, re.MULTILINE | re.IGNORECASE)
    if not match:
        raise ChangelogError("Could not find version in TOC file")
    return match.group(1).strip()


def parse_version(version):
    """Parse X.Y.Z or X.Y.Z-beta.N into a comparable tuple."""
    match = VERSION_RE.match(version or "")
    if not match:
        return None
    major, minor, patch, beta = match.groups()
    return (int(major), int(minor), int(patch), int(beta) if beta is not None else None)


def is_beta_version(version):
    """Return True when version is a beta prerelease."""
    parsed = parse_version(version)
    return parsed is not None and parsed[3] is not None


def same_release_train(left, right):
    """Return True when two versions share major.minor.patch."""
    lhs = parse_version(left)
    rhs = parse_version(right)
    return bool(lhs and rhs and lhs[:3] == rhs[:3])


def section_heading(version, date_text):
    """Return a Keep-a-Changelog version heading."""
    return f"## [{version}] - {date_text}"


def parse_changelog_sections(text):
    """Split changelog markdown into the preface plus version sections."""
    matches = list(SECTION_RE.finditer(text or ""))
    preface = text[: matches[0].start()] if matches else (text or "")
    sections = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        heading = match.group(0).strip()
        version = match.group(1).strip()
        date_text = (match.group(2) or "").strip()
        body = text[match.end():end].strip("\n")
        sections.append(
            {
                "heading": heading,
                "version": version,
                "date": date_text,
                "body": body,
                "text": text[match.start():end].strip("\n"),
                "is_beta": is_beta_version(version) or version == "Unreleased - Beta",
            }
        )
    return preface, sections


def find_section(sections, version):
    """Return the section for an exact version, if present."""
    for section in sections:
        if section["version"] == version:
            return section
    return None


def extract_bullets(section_text):
    """Return (category, text) bullets from a changelog section."""
    bullets = []
    category = "Changed"
    current = None
    for raw_line in (section_text or "").splitlines():
        stripped = raw_line.strip()
        if stripped.startswith("### ") and stripped[4:] in CATEGORIES:
            if current:
                bullets.append(current)
                current = None
            category = stripped[4:]
            continue
        if stripped.startswith("## "):
            continue
        if stripped.startswith("- "):
            if current:
                bullets.append(current)
            current = (category, stripped[2:].strip())
            continue
        if current and stripped and not stripped.startswith("#"):
            current = (current[0], f"{current[1]} {stripped}".strip())
    if current:
        bullets.append(current)
    return bullets


def is_placeholder_text(text):
    """Return True for the historical empty-diff fallback sentence."""
    return bool(PLACEHOLDER_RE.search(text or ""))


def is_user_facing_path(path):
    """Return True when a path can affect packaged addon behavior."""
    normalized = path.replace("\\", "/")
    name = Path(normalized).name
    if name in INTERNAL_PATH_NAMES or normalized in INTERNAL_PATH_NAMES:
        return False
    if any(normalized.startswith(prefix) for prefix in INTERNAL_PATH_PREFIXES):
        return False
    return any(normalized.startswith(prefix) for prefix in ADDON_PATHS)


def is_metadata_only_path(path):
    """Return True for TOC/version metadata that is not a user-facing change."""
    normalized = path.replace("\\", "/")
    return normalized.endswith(".toc")


def classify_changed_files(paths):
    """Split changed paths into user-facing addon files vs internal files."""
    user_facing = []
    internal = []
    for path in paths:
        if is_user_facing_path(path) and not is_metadata_only_path(path):
            user_facing.append(path)
        else:
            internal.append(path)
    return user_facing, internal


def is_automation_message(message):
    """Return True for release-automation commits that should not be analyzed."""
    lowered = (message or "").strip().lower()
    return any(lowered.startswith(prefix) for prefix in AUTOMATION_MESSAGE_PREFIXES)


def peel_automation_commit(start="HEAD"):
    """Walk past trailing changelog/badge/version automation commits."""
    current = run_git(["rev-parse", start])
    seen = set()
    while current and current not in seen:
        seen.add(current)
        message = run_git(["log", "-1", "--pretty=%B", current])
        parent_count = run_git(["rev-list", "--parents", "-n", "1", current]).count(" ")
        if not is_automation_message(message) or parent_count != 1:
            return current
        parent = run_git(["rev-parse", f"{current}^"], check=False)
        if not parent:
            return current
        current = parent
    return current


def latest_stable_tag(exclude_version=None):
    """Return the newest vX.Y.Z tag that is not the current version."""
    tags = run_git(["tag", "--list", "v*.*.*", "--sort=-v:refname"], check=False)
    excluded = f"v{exclude_version}" if exclude_version else None
    for tag in tags.splitlines():
        if not STABLE_TAG_RE.match(tag):
            continue
        if excluded and tag == excluded:
            continue
        if run_git(["rev-parse", "--verify", tag], check=False):
            return tag
    return None


def latest_promote_merge(start="HEAD"):
    """Return the newest Promote Beta to Main merge reachable from start."""
    return run_git(
        [
            "log",
            start,
            "--grep=^chore: promote beta to main",
            "--merges",
            "-n",
            "1",
            "--pretty=%H",
        ],
        check=False,
    )


def previous_main_tip(head="HEAD", current_version=None):
    """Identify the main tip from before the current promotion cycle."""
    tag = latest_stable_tag(exclude_version=current_version)
    if tag:
        return tag

    merge = latest_promote_merge(head)
    if merge:
        first_parent = run_git(["rev-parse", f"{merge}^1"], check=False)
        head_sha = run_git(["rev-parse", head], check=False)
        if first_parent and head_sha:
            only_followup = True
            commits = run_git(
                ["rev-list", "--first-parent", f"{merge}..{head_sha}"],
                check=False,
            )
            for sha in commits.splitlines():
                message = run_git(["log", "-1", "--pretty=%B", sha])
                if not is_automation_message(message):
                    only_followup = False
                    break
            if only_followup:
                return first_parent
            previous = run_git(
                [
                    "log",
                    f"{merge}^1",
                    "--grep=^chore: promote beta to main",
                    "--merges",
                    "-n",
                    "1",
                    "--pretty=%H",
                ],
                check=False,
            )
            if previous:
                return run_git(["rev-parse", f"{previous}^1"], check=False) or previous
        return first_parent or merge

    merge_base = run_git(["merge-base", head, "origin/main"], check=False)
    return merge_base or None


def resolve_range(mode, head_ref=None, base_ref=None, version=None):
    """Return the git range that this changelog run should analyze."""
    head = head_ref or "HEAD"
    if base_ref:
        return {
            "base": run_git(["rev-parse", base_ref]),
            "head": run_git(["rev-parse", head]),
            "mode": mode,
            "label": f"{base_ref}...{head}",
        }

    if mode == "promote":
        base = previous_main_tip(head=head, current_version=version)
        if not base:
            raise ChangelogError("Could not determine the previous main promotion boundary")
        return {
            "base": run_git(["rev-parse", base]),
            "head": run_git(["rev-parse", head]),
            "mode": mode,
            "label": f"{base}...{head}",
        }

    peeled = peel_automation_commit(head)
    parent_line = run_git(["rev-list", "--parents", "-n", "1", peeled])
    parents = parent_line.split()[1:]
    if len(parents) >= 2:
        base = parents[0]
    else:
        base = run_git(["rev-parse", f"{peeled}^"], check=False)
        if not base:
            raise ChangelogError("Could not determine a previous commit for the beta changelog range")
    return {
        "base": base,
        "head": peeled,
        "mode": mode,
        "label": f"{base[:8]}...{peeled[:8]}",
    }


def list_changed_files(base, head):
    """Return changed file paths in the analysis range."""
    output = run_git(["diff", "--name-only", f"{base}...{head}", "--", *ADDON_PATHS])
    files = []
    for line in output.splitlines():
        path = line.strip()
        if path:
            files.append(path)
    return files


def list_commits(base, head):
    """Return non-automation commits between base and head."""
    output = run_git(
        ["log", "--no-merges", "--pretty=%H%x09%s", f"{base}...{head}"],
        check=False,
    )
    commits = []
    for line in output.splitlines():
        if "\t" not in line:
            continue
        sha, subject = line.split("\t", 1)
        if is_automation_message(subject):
            continue
        body = run_git(["log", "-1", "--pretty=%B", sha], check=False)
        commits.append({"sha": sha, "subject": subject.strip(), "body": body.strip()})
    merge_output = run_git(
        ["log", "--merges", "--pretty=%H%x09%s", f"{base}...{head}"],
        check=False,
    )
    for line in merge_output.splitlines():
        if "\t" not in line:
            continue
        sha, subject = line.split("\t", 1)
        if is_automation_message(subject):
            continue
        body = run_git(["log", "-1", "--pretty=%B", sha], check=False)
        commits.append({"sha": sha, "subject": subject.strip(), "body": body.strip()})
    return commits


def collect_diff(base, head):
    """Return a budgeted addon diff plus a always-complete stat summary."""
    stat = run_git(["diff", "--stat", f"{base}...{head}", "--", *ADDON_PATHS], check=False)
    name_status = run_git(
        ["diff", "--name-status", f"{base}...{head}", "--", *ADDON_PATHS],
        check=False,
    )
    patch = run_git(["diff", f"{base}...{head}", "--", *ADDON_PATHS], check=False)
    if len(patch) > MAX_DIFF_CHARS:
        patch = patch[:MAX_DIFF_CHARS] + "\n... (diff truncated; use file list and commit/PR context)\n"
    return {"stat": stat, "name_status": name_status, "patch": patch}


def extract_pr_numbers(commits):
    """Return unique PR numbers mentioned in commit subjects or bodies."""
    found = []
    seen = set()
    for commit in commits:
        blob = f"{commit.get('subject', '')}\n{commit.get('body', '')}"
        for match in PR_RE.finditer(blob):
            number = match.group(1)
            if number not in seen:
                seen.add(number)
                found.append(number)
    return found


def github_api_json(url, token):
    """GET a GitHub API URL and decode JSON, or return None."""
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "spectrumfederation-changelog",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as error:
        print(f"[changelog] Warning: GitHub API request failed: {error}")
        return None


def fetch_pull_requests(pr_numbers, token, repo):
    """Fetch PR title/body/labels for changelog context."""
    if not token or not repo:
        return []
    pulls = []
    for number in pr_numbers:
        payload = github_api_json(
            f"https://api.github.com/repos/{repo}/pulls/{number}",
            token,
        )
        if not payload:
            continue
        labels = [
            label.get("name", "")
            for label in payload.get("labels", [])
            if label.get("name")
        ]
        pulls.append(
            {
                "number": number,
                "title": (payload.get("title") or "").strip(),
                "body": (payload.get("body") or "").strip(),
                "labels": labels,
            }
        )
    return pulls


def load_changelog_text(path=CHANGELOG_PATH, ref=None):
    """Read changelog markdown from the working tree or a git ref."""
    if ref:
        text = run_git(["show", f"{ref}:CHANGELOG.md"], check=False)
        if text:
            return text
    if path.exists():
        return path.read_text(encoding="utf-8")
    return ""


def beta_sections_for_train(sections, version):
    """Return beta sections that belong to the current X.Y.Z release train."""
    matched = []
    for section in sections:
        if section["is_beta"] and same_release_train(section["version"], version):
            matched.append(section)
    return matched


def features_for_paths(paths):
    """Return catalog feature names implicated by changed paths."""
    names = []
    for feature in FEATURE_CATALOG:
        if feature["name"] not in names and any(
            any(path.startswith(prefix) or prefix.startswith(path) for path in paths)
            for prefix in feature["paths"]
        ):
            names.append(feature["name"])
    return names


def feature_for_text(text):
    """Return the first catalog feature mentioned in free text."""
    lowered = (text or "").lower()
    for feature in FEATURE_CATALOG:
        if feature["name"].lower() in lowered or any(alias in lowered for alias in feature["aliases"]):
            return feature["name"]
    return None


def normalize_bullet_text(text):
    """Clean merge-message leftovers from a changelog bullet."""
    cleaned = re.sub(r"\s+", " ", (text or "").strip())
    cleaned = re.sub(r"^Merge pull request #\d+ from \S+\s*", "", cleaned)
    cleaned = re.sub(
        r"^(feat|fix|docs|chore|test|refactor|style|build|ci|perf)(?:\([^)]+\))?:\s*",
        "",
        cleaned,
        flags=re.IGNORECASE,
    )
    cleaned = cleaned.strip(" -")
    if cleaned and cleaned[0].islower():
        cleaned = cleaned[0].upper() + cleaned[1:]
    return cleaned


def is_internal_subject(text):
    """Return True for commit subjects that should not become changelog bullets."""
    lowered = (text or "").strip().lower()
    if not lowered or lowered.startswith("merge "):
        return True
    if is_automation_message(lowered):
        return True
    return any(lowered.startswith(prefix) for prefix in INTERNAL_SUBJECT_PREFIXES)


def context_blob(context):
    """Flatten gathered context into one grounding string."""
    parts = [
        context.get("version", ""),
        context.get("diff", {}).get("stat", ""),
        context.get("diff", {}).get("name_status", ""),
        " ".join(context.get("user_facing_files", [])),
    ]
    for commit in context.get("commits", []):
        parts.append(commit.get("subject", ""))
        parts.append(commit.get("body", ""))
    for pull in context.get("pull_requests", []):
        parts.append(pull.get("title", ""))
        parts.append(pull.get("body", ""))
    for section in context.get("beta_sections", []):
        parts.append(section.get("text", ""))
    return "\n".join(parts).lower()


def entry_is_grounded(text, blob):
    """Require at least one meaningful token from the entry to appear in context."""
    tokens = [
        token
        for token in re.findall(r"[a-zA-Z][a-zA-Z0-9/+_-]{3,}", text or "")
        if token.lower() not in {"added", "changed", "fixed", "removed", "update", "updates"}
    ]
    if not tokens:
        return False
    lowered_blob = blob or ""
    return any(token.lower() in lowered_blob for token in tokens)


def validate_ai_payload(payload, context):
    """Validate structured model output. Return (entries, error)."""
    if not isinstance(payload, dict):
        return None, "model output was not an object"
    if payload.get("skip") is True:
        return None, payload.get("reason") or "model asked to skip"
    if payload.get("confidence") != "high":
        return None, f"model confidence was {payload.get('confidence')!r}, not 'high'"

    raw_entries = payload.get("entries")
    if not isinstance(raw_entries, list):
        return None, "model entries were missing"
    if len(raw_entries) > MAX_ENTRIES:
        return None, f"model returned more than {MAX_ENTRIES} entries"

    blob = context_blob(context)
    entries = []
    for item in raw_entries:
        if not isinstance(item, dict):
            return None, "model entry was not an object"
        category = item.get("category")
        text = normalize_bullet_text(item.get("text") or "")
        if category not in CATEGORIES:
            return None, f"invalid category {category!r}"
        if not text:
            return None, "empty changelog entry"
        if len(text) > MAX_ENTRY_CHARS:
            return None, "changelog entry exceeded length limit"
        if is_placeholder_text(text):
            return None, "model returned the infrastructure placeholder"
        if text.startswith("#"):
            return None, "model returned a heading instead of a bullet"
        if not entry_is_grounded(text, blob):
            return None, f"ungrounded entry: {text}"
        entries.append({"category": category, "text": text})

    if not entries:
        return None, "model returned no usable entries"
    return entries, None


def render_section(version, date_text, entries):
    """Render a changelog section from structured entries."""
    grouped = {category: [] for category in CATEGORIES}
    seen = set()
    for entry in entries:
        key = (entry["category"], entry["text"].lower())
        if key in seen:
            continue
        seen.add(key)
        grouped[entry["category"]].append(entry["text"])

    lines = [section_heading(version, date_text), ""]
    for category in CATEGORIES:
        items = grouped[category]
        if not items:
            continue
        lines.append(f"### {category}")
        for item in items:
            lines.append(f"- {item}")
        lines.append("")
    return "\n".join(lines).strip()


def normalize_changelog(text):
    """Collapse excess blank lines without rewriting section text."""
    normalized = re.sub(r"\n{3,}", "\n\n", (text or "").strip() + "\n")
    if not normalized.startswith("# Changelog"):
        normalized = "# Changelog\n\n" + normalized
    return normalized


def replace_or_insert_section(changelog_text, version, new_section, allow_replace=False):
    """Insert a section after the preface, or replace it when allowed."""
    preface, sections = parse_changelog_sections(changelog_text)
    existing = find_section(sections, version)
    if existing and not allow_replace:
        return changelog_text, False
    if existing:
        rebuilt = [preface.rstrip(), "", new_section]
        for section in sections:
            if section["version"] != version:
                rebuilt.extend(["", section["text"]])
        return normalize_changelog("\n".join(rebuilt)), True

    rebuilt = [preface.rstrip(), "", new_section]
    for section in sections:
        rebuilt.extend(["", section["text"]])
    return normalize_changelog("\n".join(rebuilt)), True


def strip_beta_sections(changelog_text, keep_other_trains=True, current_version=None):
    """Remove beta version sections from a main changelog."""
    preface, sections = parse_changelog_sections(changelog_text)
    kept = []
    removed = []
    for section in sections:
        if not section["is_beta"]:
            kept.append(section)
            continue
        if keep_other_trains and current_version and not same_release_train(section["version"], current_version):
            kept.append(section)
            continue
        removed.append(section["heading"])
    rebuilt = [preface.rstrip()]
    for section in kept:
        rebuilt.extend(["", section["text"]])
    return normalize_changelog("\n".join(rebuilt)), removed


def categorize_title(title, labels=None):
    """Guess a changelog category from a title and optional labels."""
    lowered = (title or "").lower()
    label_text = " ".join(labels or []).lower()
    if any(word in lowered or word in label_text for word in ("fix", "bug", "issue")):
        return "Fixed"
    if any(word in lowered for word in ("remove", "delete", "deprecate")):
        return "Removed"
    if any(word in lowered for word in ("add", "new", "implement", "introduce")):
        return "Added"
    return "Changed"


def merge_body_summaries(commits):
    """Extract useful follow-up lines from merge commit messages."""
    summaries = []
    for commit in commits or []:
        subject = commit.get("subject") or ""
        if not subject.lower().startswith("merge pull request"):
            continue
        for line in (commit.get("body") or "").splitlines():
            cleaned = normalize_bullet_text(line)
            if cleaned and not cleaned.lower().startswith("merge pull request"):
                summaries.append(cleaned)
                break
    return summaries


def fallback_entries(context):
    """Build grounded entries without calling a model."""
    entries = []
    seen = set()

    def add(category, text):
        cleaned = normalize_bullet_text(text)
        if not cleaned or is_placeholder_text(cleaned) or is_internal_subject(cleaned):
            return
        key = (category, cleaned.lower())
        if key in seen:
            return
        seen.add(key)
        entries.append({"category": category, "text": cleaned})

    if context.get("mode") == "promote":
        grouped = {}
        for section in context.get("beta_sections", []):
            for category, text in extract_bullets(section.get("text", "")):
                cleaned = normalize_bullet_text(text)
                if not cleaned or is_placeholder_text(cleaned):
                    continue
                feature = feature_for_text(cleaned) or "other"
                grouped.setdefault(feature, []).append((category, cleaned))

        user_features = set(context.get("features", []))
        for feature, items in grouped.items():
            if feature != "other" and user_features and feature not in user_features:
                continue
            if feature != "other" and len(items) > 1:
                added = [text for category, text in items if category == "Added"]
                candidates = added or [text for _category, text in items]
                primary = max(candidates, key=len)
                category = "Added" if added else items[0][0]
                add(category, primary)
                continue
            for category, text in items:
                add(category, text)

        if entries:
            return entries

    for pull in context.get("pull_requests", []):
        title = normalize_bullet_text(pull.get("title") or "")
        if title:
            add(categorize_title(title, pull.get("labels")), title)

    if entries:
        return entries

    for summary in merge_body_summaries(context.get("commits")):
        add(categorize_title(summary), summary)

    if entries:
        return entries

    for commit in context.get("commits", []):
        subject = commit.get("subject") or ""
        if is_internal_subject(subject):
            continue
        cleaned = normalize_bullet_text(subject)
        if cleaned:
            add(categorize_title(cleaned), cleaned)

    if entries:
        return entries

    for feature in context.get("features", []):
        add("Added", f"Added {feature}")
    return entries


def build_prompt(context):
    """Build a mode-specific prompt that contains every fact the model may use."""
    glossary = "\n".join(f"- {feature['name']}" for feature in FEATURE_CATALOG)
    commit_lines = "\n".join(
        f"- {commit['subject']}" for commit in context.get("commits", [])
    ) or "- (none)"
    pr_lines = []
    for pull in context.get("pull_requests", []):
        body = re.sub(r"\s+", " ", pull.get("body") or "")[:800]
        pr_lines.append(f"- #{pull['number']}: {pull['title']}" + (f" — {body}" if body else ""))
    beta_notes = "\n\n".join(section.get("text", "") for section in context.get("beta_sections", [])) or "(none)"
    previous_stable = context.get("previous_stable_section") or "(none)"
    files = "\n".join(f"- {path}" for path in context.get("user_facing_files", [])) or "- (none)"

    if context.get("mode") == "promote":
        task = """You are consolidating a SpectrumFederation beta cycle into the stable main changelog.

Describe the NET user-facing result of moving from the previous main release to this new stable version.

Rules:
- Consolidate related beta iterations of the same feature into one final result.
- Keep unrelated user-facing changes as separate entries.
- Do not narrate intermediate beta bugfixes if they are already implied by the final feature.
- Omit changes that were reverted and are absent from the net diff / file list.
- Do not repeat items already present in the previous stable changelog section.
- Do not invent features, bug fixes, or settings.
- Ignore CI, tests, docs, formatting, and internal refactors unless users can observe them.
- Prefer addon/docs terminology from the glossary when it matches the changes.
- If you cannot confidently describe a change from the provided context, omit it.
- If nothing user-facing remains, set skip=true.
- Return JSON only."""
    else:
        task = """You are writing an incremental SpectrumFederation beta changelog entry for this development update.

Describe the user-facing change introduced in this range only.

Rules:
- Incremental beta notes are allowed: adding a feature, then later improving or fixing it, may be a new entry.
- Do not invent features, bug fixes, or settings.
- Ignore CI, tests, docs, formatting, and internal refactors unless users can observe them.
- Prefer addon/docs terminology from the glossary when it matches the changes.
- Do not copy raw git subjects when a clearer user-facing description is available.
- If you cannot confidently describe a change from the provided context, omit it.
- If nothing user-facing remains, set skip=true.
- Return JSON only."""

    prompt = f"""{task}

Version: {context.get("version")}
Mode: {context.get("mode")}
Git range: {context.get("range", {}).get("label")}

Known feature names:
{glossary}

User-facing files in range:
{files}

Diff stat:
{context.get("diff", {}).get("stat") or "(none)"}

Diff name-status:
{context.get("diff", {}).get("name_status") or "(none)"}

Commits:
{commit_lines}

Pull requests:
{chr(10).join(pr_lines) or "- (none)"}

Beta changelog notes in this release train:
{beta_notes}

Previous stable changelog section:
{previous_stable}

Addon diff (may be truncated):
{context.get("diff", {}).get("patch") or "(none)"}

Respond with JSON only in this exact shape:
{{
  "confidence": "high" or "low",
  "skip": false,
  "reason": "",
  "entries": [
    {{"category": "Added|Changed|Fixed|Removed", "text": "User-facing sentence."}}
  ]
}}
"""
    if len(prompt) > MAX_PROMPT_CHARS:
        prompt = prompt[:MAX_PROMPT_CHARS] + "\n... (prompt truncated)\n"
    return prompt


def parse_copilot_jsonl(output):
    """Extract the last assistant message from Copilot CLI JSONL output."""
    texts = []
    for line in (output or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        event_type = event.get("type")
        data = event.get("data") or event
        if event_type in {"assistant.message", "assistant"} or data.get("role") == "assistant":
            content = data.get("content") or data.get("text") or event.get("content")
            if isinstance(content, str) and content.strip():
                texts.append(content.strip())
            elif isinstance(content, list):
                joined = "".join(
                    part.get("text", "")
                    for part in content
                    if isinstance(part, dict)
                ).strip()
                if joined:
                    texts.append(joined)
    return texts[-1] if texts else None


def extract_json_object(text):
    """Parse a JSON object from model text that may include fences."""
    if not text:
        return None
    cleaned = text.strip()
    cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
    cleaned = re.sub(r"\s*```$", "", cleaned)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", cleaned, re.DOTALL)
        if not match:
            return None
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            return None


def call_openai_compatible(prompt, token):
    """Call an optional OpenAI-compatible chat endpoint."""
    base_url = os.environ.get("CHANGELOG_AI_BASE_URL", "").rstrip("/")
    if not base_url or not token:
        return None
    model = os.environ.get("CHANGELOG_AI_MODEL", "gpt-4o")
    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": "You write SpectrumFederation changelog entries. Reply with JSON only.",
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.2,
        "max_tokens": 1200,
    }
    request = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.loads(response.read().decode("utf-8"))
        return result["choices"][0]["message"]["content"]
    except (urllib.error.URLError, TimeoutError, KeyError, IndexError, json.JSONDecodeError, OSError) as error:
        print(f"[changelog] OpenAI-compatible API unavailable: {error}")
        return None


def call_copilot_cli(prompt):
    """Call Copilot CLI in programmatic mode when it is installed."""
    from shutil import which

    if which("copilot") is None:
        return None
    command = [
        "copilot",
        "-p",
        prompt,
        "--no-ask-user",
        "--output-format",
        "json",
        "--deny-tool",
        "*",
    ]
    env = os.environ.copy()
    env.setdefault("COPILOT_MODEL", os.environ.get("CHANGELOG_AI_MODEL", "gpt-4o"))
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"[changelog] Copilot CLI unavailable: {error}")
        return None
    if result.returncode != 0:
        print(f"[changelog] Copilot CLI exited {result.returncode}")
        if result.stderr:
            print(result.stderr.strip())
        return None
    return parse_copilot_jsonl(result.stdout) or result.stdout.strip() or None


def request_ai_entries(context, token):
    """Ask an available model for structured entries, then validate them."""
    prompt = build_prompt(context)
    raw = call_openai_compatible(prompt, os.environ.get("CHANGELOG_AI_API_KEY") or token)
    if raw is None:
        raw = call_copilot_cli(prompt)
    if raw is None:
        print("[changelog] No AI provider available; using deterministic fallback")
        return None, "no AI provider available"

    payload = extract_json_object(raw)
    if payload is None:
        return None, "model did not return JSON"
    entries, error = validate_ai_payload(payload, context)
    if error:
        print(f"[changelog] Rejected AI output: {error}")
        return None, error
    print("[changelog] Accepted validated AI changelog entries")
    return entries, None


def gather_context(mode, version, token, repo, head_ref=None, base_ref=None, notes_ref=None):
    """Collect every deterministic input needed to write a changelog section."""
    analysis_range = resolve_range(mode, head_ref=head_ref, base_ref=base_ref, version=version)
    files = list_changed_files(analysis_range["base"], analysis_range["head"])
    user_facing, internal = classify_changed_files(files)
    commits = list_commits(analysis_range["base"], analysis_range["head"])
    pulls = fetch_pull_requests(extract_pr_numbers(commits), token, repo)
    diff = collect_diff(analysis_range["base"], analysis_range["head"])
    changelog_text = load_changelog_text()
    notes_text = load_changelog_text(ref=notes_ref) if notes_ref else changelog_text
    _preface, sections = parse_changelog_sections(notes_text)
    _working_preface, working_sections = parse_changelog_sections(changelog_text)
    previous_stable = None
    for section in working_sections:
        if not section["is_beta"]:
            previous_stable = section["text"]
            break
    return {
        "mode": mode,
        "version": version,
        "range": analysis_range,
        "files": files,
        "user_facing_files": user_facing,
        "internal_files": internal,
        "features": features_for_paths(user_facing),
        "commits": commits,
        "pull_requests": pulls,
        "diff": diff,
        "changelog_text": changelog_text,
        "beta_sections": beta_sections_for_train(sections, version),
        "previous_stable_section": previous_stable,
        "existing_section": find_section(working_sections, version),
    }


def choose_entries(context, token):
    """Return structured entries or None when nothing should be written."""
    if context.get("existing_section") and not is_placeholder_text(context["existing_section"].get("text", "")):
        print(f"[changelog] Section for {context['version']} already exists; leaving it unchanged")
        return None
    has_promote_notes = context.get("mode") == "promote" and context.get("beta_sections")
    if not context.get("user_facing_files") and not has_promote_notes:
        print("[changelog] No user-facing addon changes in range; not writing an entry")
        return None

    ai_entries, ai_error = request_ai_entries(context, token)
    if ai_entries:
        return ai_entries

    fallback = fallback_entries(context)
    if fallback:
        print("[changelog] Using deterministic fallback entries")
        return fallback

    if ai_error:
        raise ChangelogError(
            f"Refusing to write a guessed changelog entry ({ai_error})"
        )
    print("[changelog] No grounded changelog entries available; skipping")
    return None


def apply_changelog(context, entries, date_text):
    """Write the current version section and preserve historical sections."""
    version = context["version"]
    changelog_text = context["changelog_text"]
    if context["mode"] == "promote":
        changelog_text, removed = strip_beta_sections(
            changelog_text,
            keep_other_trains=False,
            current_version=version,
        )
        for heading in removed:
            print(f"[changelog] Removed beta section: {heading}")

    rendered = render_section(version, date_text, entries)
    updated, changed = replace_or_insert_section(
        changelog_text,
        version,
        rendered,
        allow_replace=is_placeholder_text((context.get("existing_section") or {}).get("text", "")),
    )
    if not changed:
        print("[changelog] Changelog already contained this version; no write needed")
        return False
    CHANGELOG_PATH.write_text(updated, encoding="utf-8")
    print(f"[changelog] Wrote {CHANGELOG_PATH} section {version}")
    print(rendered)
    return True


def determine_mode(branch_name, version):
    """Return beta or promote from branch + version, with env override."""
    override = os.environ.get("CHANGELOG_MODE", "").strip().lower()
    if override in {"beta", "promote"}:
        return override
    if branch_name == "main" and not is_beta_version(version):
        return "promote"
    return "beta"


def parse_args(argv=None):
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(description="Update SpectrumFederation CHANGELOG.md")
    parser.add_argument(
        "--print-plan",
        action="store_true",
        help="Print the resolved range and proposed section without writing",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    token = os.environ.get("GITHUB_TOKEN")
    if not token and not args.print_plan:
        print("Error: GITHUB_TOKEN environment variable not set")
        return 1

    if not TOC_PATH.exists():
        print(f"Error: TOC file not found at {TOC_PATH}")
        return 1

    version = os.environ.get("CHANGELOG_VERSION") or read_toc_version()
    branch_name = os.environ.get("BRANCH_NAME", "")
    mode = determine_mode(branch_name, version)
    date_text = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    print(f"[changelog] version={version} branch={branch_name or '(unset)'} mode={mode}")

    try:
        context = gather_context(
            mode,
            version,
            token,
            repo,
            head_ref=os.environ.get("CHANGELOG_HEAD_REF") or None,
            base_ref=os.environ.get("CHANGELOG_BASE_REF") or None,
            notes_ref=os.environ.get("CHANGELOG_NOTES_REF") or None,
        )
        print(f"[changelog] range {context['range']['label']}")
        print(f"[changelog] user-facing files: {len(context['user_facing_files'])}")
        print(f"[changelog] commits: {len(context['commits'])}")
        print(f"[changelog] pull requests: {len(context['pull_requests'])}")
        print(f"[changelog] beta notes: {len(context['beta_sections'])}")

        entries = choose_entries(context, token)
        if args.print_plan:
            print("[changelog] plan entries:")
            print(json.dumps(entries, indent=2))
            if entries:
                print(render_section(version, date_text, entries))
            return 0
        if not entries:
            return 0
        apply_changelog(context, entries, date_text)
        return 0
    except ChangelogError as error:
        print(f"::error ::{error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
