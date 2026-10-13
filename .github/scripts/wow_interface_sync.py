"""
Synchronize WoW Interface and addon versions on main and beta branches.

Supports the manual Update WoW Game Version workflow: accept a human-readable
Retail version, validate it against live Retail, compute independent main/beta
TOC updates, and emit a plan for the workflow to mutate branches and publish.

Commit/push side effects are optional and disabled by default. Publishing is
owned by the workflow via publish_release.py.
"""

import argparse
import json
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib import error, request

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

# Lazy import: --materialize-helpers must work when this file is bootstrapped alone
# into /tmp before validate_packaging.py exists beside it.
validate_packaging = None

PATCH_VERSIONS_URL_TEMPLATE = "https://{region}.patch.battle.net:1119/wow/versions"
BLIZZTRACK_VERSIONS_URL = "https://blizztrack.com/view/wow?type=versions"
BLIZZMETA_VERSIONS_URL = "https://www.blizzmeta.com/view/wow?type=versions"
INTERFACE_MIN = 100000
INTERFACE_MAX = 999999
USER_AGENT = "SpectrumFederation-WoWInterfaceSync/1.0 (+https://github.com/OsulivanAB/SpectrumFederation)"
NON_RETAIL_TOKENS = ("ptr", "classic", "wrath", "cata", "mop", "sod", "season of discovery")
# Window before/after a version match when checking for nearby "Version Name" marker cards.
MARKER_CONTEXT_LEADING_CHARS = 120
MARKER_CONTEXT_TRAILING_CHARS = 320
# Small window for immediate textual hints near the exact version token.
NEARBY_CONTEXT_CHARS = 80
# Larger window to evaluate surrounding HTML/text for fallback scoring signals.
SCORING_CONTEXT_CHARS = 240
NON_RETAIL_PATTERN = re.compile(
    rf"\b(?:{'|'.join(re.escape(token) for token in NON_RETAIL_TOKENS)})\b"
)
# Generated release-metadata paths that game-version sync may reconcile automatically.
GENERATED_METADATA_PATHS = (
    "SpectrumFederation/SpectrumFederation.toc",
    "SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc",
    "SpectrumFederation_RCLootCouncilIntegration/SpectrumFederation_RCLootCouncilIntegration.toc",
    "README.md",
    "CHANGELOG.md",
)
GENERATED_METADATA_PATH_SET = set(GENERATED_METADATA_PATHS)
README_BADGE_LINE_RE = re.compile(
    r"^!\[(?:Interface|Track|Addon Version)\]\(https://img\.shields\.io/badge/[^)]+\)\s*$"
)
TOC_METADATA_LINE_RE = re.compile(r"^##\s*(?:Interface|Version):\s*.*$")
HISTORY_SYNC_COMMIT_PREFIX = "chore: sync main game-version update into beta"


def _validate_packaging():
    """Import validate_packaging from SCRIPTS_DIR on first use."""
    global validate_packaging
    if validate_packaging is None:
        import validate_packaging as _vp

        validate_packaging = _vp
    return validate_packaging


def _update_changelog():
    """Import update_changelog from SCRIPTS_DIR on first use."""
    import update_changelog as _uc

    return _uc


class VersionInfo:
    def __init__(self, raw, kind, major=None, minor=None, patch=None, label=None, pre=None, integer=None):
        self.raw = raw
        self.kind = kind  # "semver" or "integer"
        self.major = major
        self.minor = minor
        self.patch = patch
        self.label = label
        self.pre = pre
        self.integer = integer


def _is_plausible_interface(interface):
    return INTERFACE_MIN <= int(interface) <= INTERFACE_MAX


def _validate_interface(interface):
    interface_int = int(interface)
    if not _is_plausible_interface(interface_int):
        raise RuntimeError(f"Interface must be between {INTERFACE_MIN} and {INTERFACE_MAX}, got {interface_int}")
    return interface_int


def _backoff_sleep_seconds(attempt, base_sleep, max_sleep):
    base_delay = min(max_sleep, base_sleep * (2 ** (attempt - 1)))
    jitter = random.uniform(0, min(1.0, max_sleep / 10.0))
    return min(max_sleep, base_delay + jitter)


def http_get_with_retries(url, *, headers=None, timeout=30, attempts=3, base_sleep=1, max_sleep=20):
    headers = dict(headers or {})
    headers.setdefault("User-Agent", USER_AGENT)
    last_error = None

    for attempt in range(1, attempts + 1):
        req = request.Request(url, headers=headers)
        try:
            with request.urlopen(req, timeout=timeout) as resp:
                return resp.read().decode("utf-8")
        except error.HTTPError as exc:
            last_error = exc
            retryable_http = exc.code in (408, 429) or exc.code >= 500
            if not retryable_http:
                break
        except (error.URLError, TimeoutError, ConnectionError) as exc:
            last_error = exc

        if attempt < attempts:
            time.sleep(_backoff_sleep_seconds(attempt, base_sleep=base_sleep, max_sleep=max_sleep))

    if last_error is None:
        raise RuntimeError(f"Failed to reach {url}: unknown error")

    code = getattr(last_error, "code", None)
    if code is not None:
        raise RuntimeError(f"HTTP {code} from {url}") from last_error

    reason = getattr(last_error, "reason", str(last_error))
    raise RuntimeError(f"Failed to reach {url}: {reason}") from last_error


def parse_version_response(response_text, region="us"):
    lines = response_text.strip().splitlines()
    region_lower = region.lower()
    for line in lines:
        if line.startswith(f"{region_lower}|"):
            parts = line.split("|")
            if len(parts) >= 6:
                candidate = parts[5]
                if re.match(r"^\d+\.\d+\.\d+\.\d+$", candidate):
                    return candidate
    raise RuntimeError("Could not parse game version from Blizzard response")


def _is_plausible_game_version(version):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        return False

    major, minor, patch, build = (int(piece) for piece in match.groups())
    return 1 <= major <= 20 and 0 <= minor <= 99 and 0 <= patch <= 99 and build > 0


def _contains_any_token(text, tokens):
    if tokens == NON_RETAIL_TOKENS:
        return bool(NON_RETAIL_PATTERN.search(text))

    for token in tokens:
        if re.search(rf"\b{re.escape(token)}\b", text):
            return True
    return False


def _iter_plausible_versions(payload_text):
    version_pattern = r"\b(\d+\.\d+\.\d+\.\d+)\b"
    for match in re.finditer(version_pattern, payload_text):
        version = match.group(1)
        if _is_plausible_game_version(version):
            yield match, version


def version_to_interface(version):
    parts = version.split(".")
    if len(parts) < 3:
        raise RuntimeError(f"Unexpected game version format: {version}")

    major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
    return int(f"{major}{minor:02d}{patch:02d}")


HUMAN_GAME_VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$")


def parse_human_game_version(raw):
    """Parse a human-readable Retail version such as 12.1.5 or 12.1.5.12345."""
    text = (raw or "").strip()
    match = HUMAN_GAME_VERSION_RE.fullmatch(text)
    if not match:
        raise RuntimeError(
            f"Invalid game version '{raw}'. Expected Major.Minor.Patch "
            "(optionally .Build), for example 12.1.5"
        )

    major, minor, patch, build = match.groups()
    major_i, minor_i, patch_i = int(major), int(minor), int(patch)
    if not (1 <= major_i <= 20 and 0 <= minor_i <= 99 and 0 <= patch_i <= 99):
        raise RuntimeError(f"Game version out of plausible Retail range: {text}")
    if build is not None and int(build) <= 0:
        raise RuntimeError(f"Game version build must be positive when provided: {text}")

    normalized = f"{major_i}.{minor_i}.{patch_i}"
    return {
        "raw": text,
        "normalized": normalized,
        "major": major_i,
        "minor": minor_i,
        "patch": patch_i,
        "build": int(build) if build is not None else None,
        "interface": _validate_interface(version_to_interface(normalized)),
    }


def verify_requested_matches_live(requested, live_interface, live_game_version=None):
    """Require the requested Interface to match the currently live Retail Interface."""
    requested_interface = int(requested["interface"])
    live_interface = _validate_interface(live_interface)
    if requested_interface != live_interface:
        live_display = live_game_version or str(live_interface)
        raise RuntimeError(
            f"Requested game version {requested['normalized']} "
            f"(Interface {requested_interface}) does not match live Retail "
            f"({live_display}, Interface {live_interface}). "
            "Refuse to update until the requested version is live."
        )
    return requested_interface


def _version_tuple(version):
    major, minor, patch, build = version.split(".")
    return int(major), int(minor), int(patch), int(build)


def parse_live_version_from_text(payload_text, source_name):
    marker_candidates = []

    for match, version in _iter_plausible_versions(payload_text):
        leading = payload_text[max(0, match.start() - MARKER_CONTEXT_LEADING_CHARS): match.start()].lower()
        trailing = payload_text[match.end(): match.end() + MARKER_CONTEXT_TRAILING_CHARS].lower()
        trailing_text = re.sub(r"<[^>]+>", " ", trailing)
        marker_context = f"{leading} {trailing_text}"
        if re.search(r"\bversion\s*name\b", marker_context) and not _contains_any_token(marker_context, NON_RETAIL_TOKENS):
            marker_candidates.append(version)

    if marker_candidates:
        return max(marker_candidates, key=_version_tuple)

    candidates = []

    for match, version in _iter_plausible_versions(payload_text):
        line_start = payload_text.rfind("\n", 0, match.start()) + 1
        line_end = payload_text.find("\n", match.end())
        if line_end == -1:
            line_end = len(payload_text)

        line_context = payload_text[line_start:line_end].lower()
        context = payload_text[max(0, match.start() - NEARBY_CONTEXT_CHARS): match.end() + NEARBY_CONTEXT_CHARS].lower()
        text_context = re.sub(
            r"<[^>]+>",
            "\n",
            payload_text[max(0, match.start() - SCORING_CONTEXT_CHARS): match.end() + SCORING_CONTEXT_CHARS],
        ).lower()
        score = 0
        if "retail" in line_context:
            score += 3
        if "live" in line_context:
            score += 3
        if "mainline" in line_context:
            score += 1
        if "version name" in text_context:
            score += 2
        if _contains_any_token(line_context, NON_RETAIL_TOKENS):
            score -= 8
        elif _contains_any_token(context, NON_RETAIL_TOKENS) or _contains_any_token(text_context, NON_RETAIL_TOKENS):
            score -= 4
        candidates.append((score, _version_tuple(version), version))

    if not candidates:
        raise RuntimeError(f"Could not find any plausible game versions in {source_name} response")

    best_score, _, best_version = max(candidates, key=lambda item: (item[0], item[1]))
    # Score 0 is accepted because some fallback pages expose clean "Version Name"
    # cards without explicit "live/retail" text near each version token.
    if best_score < 0:
        raise RuntimeError(f"Could not confidently identify LIVE retail version from {source_name} response")

    return best_version


def _resolve_patch_server(region):
    payload = http_get_with_retries(
        PATCH_VERSIONS_URL_TEMPLATE.format(region=region),
        timeout=30,
        attempts=6,
        base_sleep=1,
        max_sleep=20,
    )
    game_version = parse_version_response(payload, region=region)
    return game_version, _validate_interface(version_to_interface(game_version))


def _resolve_https_fallback():
    failures = []
    sources = [
        ("BlizzTrack", BLIZZTRACK_VERSIONS_URL, "https_blizztrack"),
        ("BlizzMeta", BLIZZMETA_VERSIONS_URL, "https_blizzmeta"),
    ]

    for source_name, source_url, strategy_name in sources:
        try:
            payload = http_get_with_retries(
                source_url,
                timeout=30,
                attempts=3,
                base_sleep=1,
                max_sleep=20,
            )
            game_version = parse_live_version_from_text(payload, source_name=source_name)
            interface_int = _validate_interface(version_to_interface(game_version))
            print(f"[resolver] Strategy B ({source_name} HTTPS fallback) succeeded")
            return game_version, interface_int, strategy_name
        except (RuntimeError, OSError, ValueError, UnicodeError) as exc:
            failures.append(f"{source_name}: {exc}")
            print(f"[resolver] Strategy B ({source_name} HTTPS fallback) failed: {exc}")

    raise RuntimeError("; ".join(failures))


def _resolve_manual_override():
    override = os.environ.get("LIVE_INTERFACE_OVERRIDE")
    if not override:
        raise RuntimeError("LIVE_INTERFACE_OVERRIDE is not set")

    try:
        interface_int = _validate_interface(override)
    except ValueError as exc:
        raise RuntimeError("LIVE_INTERFACE_OVERRIDE must be an integer") from exc
    except RuntimeError as exc:
        raise RuntimeError(f"LIVE_INTERFACE_OVERRIDE invalid: {exc}") from exc

    print("[resolver] Strategy C (manual override) succeeded")
    return None, interface_int


def resolve_live_interface(region, allow_network=True):
    override = os.environ.get("LIVE_INTERFACE_OVERRIDE")
    if override:
        print("[resolver] LIVE_INTERFACE_OVERRIDE detected; will be used if network strategies fail")

    failures = []

    if allow_network:
        try:
            game_version, interface_int = _resolve_patch_server(region)
            print(f"[resolver] Strategy A (patch server) succeeded for region '{region}'")
            return game_version, interface_int, "patch_server"
        except (RuntimeError, OSError, ValueError, UnicodeError) as exc:
            failures.append(f"Strategy A (patch server): {exc}")
            print(f"[resolver] Strategy A (patch server) failed: {exc}")

        try:
            game_version, interface_int, strategy_name = _resolve_https_fallback()
            return game_version, interface_int, strategy_name
        except (RuntimeError, OSError, ValueError, UnicodeError) as exc:
            failures.append(f"Strategy B (HTTPS fallback): {exc}")
            print(f"[resolver] Strategy B (HTTPS fallback) failed: {exc}")
    else:
        failures.append("Strategy A (patch server): skipped (--no-network)")
        failures.append("Strategy B (HTTPS fallback): skipped (--no-network)")

    try:
        game_version, interface_int = _resolve_manual_override()
        return game_version, interface_int, "manual_override"
    except (RuntimeError, OSError, ValueError) as exc:
        failures.append(f"Strategy C (manual override): {exc}")
        print(f"[resolver] Strategy C (manual override) failed: {exc}")

    failure_text = "; ".join(failures)
    raise RuntimeError(
        "Unable to resolve live interface using Strategy A (patch server), "
        "Strategy B (HTTPS fallback), or Strategy C (manual override). "
        f"Failures: {failure_text}"
    )


def parse_version(raw):
    raw = raw.strip()
    if re.fullmatch(r"\d+", raw):
        return VersionInfo(raw, kind="integer", integer=int(raw))

    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z]+)\.(\d+))?", raw)
    if not match:
        raise RuntimeError(f"Unsupported version format: {raw}")

    major, minor, patch = int(match.group(1)), int(match.group(2)), int(match.group(3))
    label = match.group(4)
    pre = int(match.group(5)) if match.group(5) else None
    return VersionInfo(raw, kind="semver", major=major, minor=minor, patch=patch, label=label, pre=pre)


def bump_main_version(info):
    if info.kind == "integer":
        return VersionInfo(str(info.integer + 1), kind="integer", integer=info.integer + 1)

    if info.label is not None or info.pre is not None:
        raise RuntimeError(f"Main branch version must be stable X.Y.Z, got {info.raw}")

    new_patch = info.patch + 1
    version = f"{info.major}.{info.minor}.{new_patch}"
    return VersionInfo(version, kind="semver", major=info.major, minor=info.minor, patch=new_patch)


def train_tuple(info):
    """Return the X.Y.Z train for a semver VersionInfo."""
    if info.kind != "semver":
        raise RuntimeError(f"Cannot derive a release train from integer version {info.raw}")
    return (info.major, info.minor, info.patch)


def bump_beta_prerelease(info):
    """Advance X.Y.Z-beta.N to beta.(N+1), or start beta.1 on a stable train."""
    if info.kind != "semver":
        raise RuntimeError(f"Beta version must be semver, got {info.raw}")

    if info.label is None or info.pre is None:
        version = f"{info.major}.{info.minor}.{info.patch}-beta.1"
        return VersionInfo(
            version,
            kind="semver",
            major=info.major,
            minor=info.minor,
            patch=info.patch,
            label="beta",
            pre=1,
        )

    if info.label.lower() != "beta":
        raise RuntimeError(f"Unsupported prerelease label on beta branch: {info.raw}")

    new_pre = info.pre + 1
    version = f"{info.major}.{info.minor}.{info.patch}-beta.{new_pre}"
    return VersionInfo(
        version,
        kind="semver",
        major=info.major,
        minor=info.minor,
        patch=info.patch,
        label="beta",
        pre=new_pre,
    )


def next_beta_after_stable(stable_info):
    """Return (stable.patch + 1)-beta.1 for a stable X.Y.Z version."""
    if stable_info.kind != "semver":
        raise RuntimeError(f"Expected semver stable version, got {stable_info.raw}")
    if stable_info.label is not None or stable_info.pre is not None:
        raise RuntimeError(f"Expected stable X.Y.Z reference, got {stable_info.raw}")

    patch = stable_info.patch + 1
    version = f"{stable_info.major}.{stable_info.minor}.{patch}-beta.1"
    return VersionInfo(
        version,
        kind="semver",
        major=stable_info.major,
        minor=stable_info.minor,
        patch=patch,
        label="beta",
        pre=1,
    )


def encode_value(info):
    if info.kind == "integer":
        return info.integer

    base = info.major * 1_000_000 + info.minor * 1_000 + info.patch
    remainder = info.pre if info.pre is not None else 999
    return base * 1000 + remainder


def decode_semver_value(value, label_hint="beta"):
    base, remainder = divmod(int(value), 1000)
    major = base // 1_000_000
    minor = (base // 1000) % 1000
    patch = base % 1000

    if remainder == 999:
        raw = f"{major}.{minor}.{patch}"
        return VersionInfo(raw, kind="semver", major=major, minor=minor, patch=patch)

    raw = f"{major}.{minor}.{patch}-{label_hint}.{remainder}"
    return VersionInfo(raw, kind="semver", major=major, minor=minor, patch=patch, label=label_hint, pre=remainder)


def decode_value(value, template):
    if template.kind == "integer":
        integer_value = int(value)
        return VersionInfo(str(integer_value), kind="integer", integer=integer_value)

    label_hint = template.label or "beta"
    return decode_semver_value(value, label_hint=label_hint)


def version_value(info):
    return encode_value(info)


def format_version(info):
    return info.raw


def read_toc_fields(toc_path):
    content = Path(toc_path).read_text(encoding="utf-8")

    interface_match = re.search(r"^## Interface:\s*(.+)$", content, re.MULTILINE)
    version_match = re.search(r"^## Version:\s*(.+)$", content, re.MULTILINE)

    if not interface_match or not version_match:
        raise RuntimeError(f"Missing Interface or Version field in {toc_path}")

    return interface_match.group(1).strip(), version_match.group(1).strip()


def extra_packaged_toc_paths(toc_path):
    """Return sibling child-addon TOC paths that must stay in lockstep."""
    toc_path = Path(toc_path)
    repo_root = toc_path.parent.parent
    extra = []
    for child_name in _validate_packaging().CHILD_ADDON_NAMES:
        child_toc = repo_root / child_name / f"{child_name}.toc"
        if child_toc.exists() and child_toc.resolve() != toc_path.resolve():
            extra.append(child_toc)
    return extra


def packaged_toc_relpaths(toc_path="SpectrumFederation/SpectrumFederation.toc"):
    """Return repo-relative TOC paths for the parent and packaged children."""
    toc_path = Path(toc_path)
    paths = [str(toc_path).replace("\\", "/")]
    parent_name = toc_path.parent.name
    for child_name in _validate_packaging().CHILD_ADDON_NAMES:
        if child_name == parent_name:
            continue
        paths.append(f"{child_name}/{child_name}.toc")
    return paths


def update_toc(toc_path, interface, version):
    path = Path(toc_path)
    content = path.read_text(encoding="utf-8")

    new_content = re.sub(r"^## Interface:.*$", f"## Interface: {interface}", content, flags=re.MULTILINE)
    new_content = re.sub(r"^## Version:.*$", f"## Version: {version}", new_content, flags=re.MULTILINE)

    if new_content != content:
        path.write_text(new_content, encoding="utf-8")
        return True
    return False


def update_packaged_tocs(toc_path, interface, version):
    """Update the primary TOC and any sibling packaged addon TOCs."""
    changed = update_toc(toc_path, interface, version)
    extra_paths = extra_packaged_toc_paths(toc_path)
    for extra_toc in extra_paths:
        if update_toc(extra_toc, interface, version):
            changed = True
            print(f"[sync] Updated sibling TOC: {extra_toc}")
    return changed


def git_config(path):
    subprocess.run(["git", "-C", str(path), "config", "user.name", "github-actions[bot]"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "github-actions[bot]@users.noreply.github.com"], check=True)


def git_commit_and_push(path, branch, toc_path, message):
    rel_paths = [os.path.relpath(toc_path, path)]
    for extra_toc in extra_packaged_toc_paths(toc_path):
        rel_paths.append(os.path.relpath(extra_toc, path))

    diff_check = subprocess.run(
        ["git", "-C", str(path), "diff", "--quiet", "--", *rel_paths],
        check=False,
    )
    if diff_check.returncode == 0:
        return False

    subprocess.run(["git", "-C", str(path), "add", *rel_paths], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-m", message], check=True)
    subprocess.run(["git", "-C", str(path), "push", "origin", branch], check=True)
    return True


def write_output(key, value):
    output_path = os.environ.get("GITHUB_OUTPUT")
    line = f"{key}={value}\n"
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write(line)
    else:
        print(line)


def compute_updated_versions(
    main_version,
    beta_version,
    main_update_needed,
    beta_update_needed=True,
):
    """Return updated main/beta versions using stable/beta release-train rules.

    Examples when both branches require an Interface update:
      main 1.5.8 / beta 1.6.0-beta.7  -> 1.5.9 / 1.6.0-beta.8
      main 1.5.8 / beta 1.5.9-beta.7  -> 1.5.9 / 1.5.10-beta.1
      main 1.5.8 / beta 1.5.8        -> 1.5.9 / 1.5.10-beta.1
    """
    if main_version.kind != beta_version.kind:
        raise RuntimeError("Main and beta use different version formats; cannot update safely")
    if main_version.kind != "semver":
        raise RuntimeError("Integer TOC versions are not supported by the game-version workflow")

    new_main_version = bump_main_version(main_version) if main_update_needed else main_version
    if new_main_version.label is not None or new_main_version.pre is not None:
        raise RuntimeError(f"Computed main version must be stable X.Y.Z, got {new_main_version.raw}")

    if not beta_update_needed:
        beta_ahead = version_value(beta_version) > version_value(new_main_version)
        return new_main_version, beta_version, beta_ahead

    if train_tuple(beta_version) > train_tuple(new_main_version):
        new_beta_version = bump_beta_prerelease(beta_version)
    else:
        new_beta_version = next_beta_after_stable(new_main_version)

    if version_value(new_beta_version) <= version_value(new_main_version):
        raise RuntimeError(
            f"Computed beta version {new_beta_version.raw} is not ahead of "
            f"main version {new_main_version.raw}"
        )
    return new_main_version, new_beta_version, True


def read_toc_fields_from_git(repo_path, git_ref, toc_path):
    """Read Interface/Version for a TOC path from a git ref."""
    rel = str(Path(toc_path)).replace("\\", "/")
    payload = subprocess.run(
        ["git", "-C", str(repo_path), "show", f"{git_ref}:{rel}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    interface_match = re.search(r"^## Interface:\s*(.+)$", payload, re.MULTILINE)
    version_match = re.search(r"^## Version:\s*(.+)$", payload, re.MULTILINE)
    if not interface_match or not version_match:
        raise RuntimeError(f"Missing Interface or Version in {git_ref}:{rel}")
    return interface_match.group(1).strip(), version_match.group(1).strip()


def resolve_git_sha(repo_path, git_ref):
    """Resolve a ref to a full commit SHA."""
    return subprocess.run(
        ["git", "-C", str(repo_path), "rev-parse", git_ref],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def verify_git_sha(repo_path, git_ref, expected_sha, *, label):
    """Abort when a branch moved away from the captured SHA."""
    current = resolve_git_sha(repo_path, git_ref)
    if current != expected_sha:
        raise RuntimeError(
            f"{label} has advanced unexpectedly: expected {expected_sha}, found {current}. "
            "Aborting without force-push or reset. Re-run the workflow to capture a fresh plan."
        )
    return current


def git_is_ancestor(repo_path, ancestor_sha, descendant_sha):
    """Return True when ancestor_sha is an ancestor of descendant_sha."""
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_path),
            "merge-base",
            "--is-ancestor",
            ancestor_sha,
            descendant_sha,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def git_merge_base(repo_path, left_sha, right_sha):
    """Return the merge-base SHA for two commits."""
    return subprocess.run(
        ["git", "-C", str(repo_path), "merge-base", left_sha, right_sha],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def list_changed_paths(repo_path, base_sha, head_sha):
    """Return repo-relative paths changed between base and head."""
    payload = subprocess.run(
        [
            "git",
            "-C",
            str(repo_path),
            "diff",
            "--name-only",
            "--no-renames",
            f"{base_sha}...{head_sha}",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line.strip().replace("\\", "/") for line in payload.splitlines() if line.strip()]


def list_unmerged_paths(repo_path):
    """Return conflicted paths in the current merge state."""
    payload = subprocess.run(
        ["git", "-C", str(repo_path), "diff", "--name-only", "--diff-filter=U"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line.strip().replace("\\", "/") for line in payload.splitlines() if line.strip()]


def read_git_blob(repo_path, git_ref, rel_path):
    """Return file contents at git_ref:rel_path, or None when missing."""
    rel = str(rel_path).replace("\\", "/")
    result = subprocess.run(
        ["git", "-C", str(repo_path), "show", f"{git_ref}:{rel}"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def strip_toc_metadata_lines(text):
    """Remove Interface/Version TOC lines for non-metadata comparisons."""
    lines = []
    for line in (text or "").splitlines():
        if TOC_METADATA_LINE_RE.match(line.strip()):
            continue
        lines.append(line)
    return "\n".join(lines).strip()


def strip_readme_badge_lines(text):
    """Remove generated Interface/Track/Version badge lines from README text."""
    lines = []
    for line in (text or "").splitlines():
        if README_BADGE_LINE_RE.match(line.strip()):
            continue
        lines.append(line)
    return "\n".join(lines).strip()


def changelog_sections_compatible(left_section, right_section):
    """Return True when two same-version changelog sections are interchangeable."""
    left_text = (left_section.get("text") or "").strip()
    right_text = (right_section.get("text") or "").strip()
    if left_text == right_text:
        return True

    changelog = _update_changelog()
    left_bullets = {
        (category, changelog.normalize_bullet_text(text).lower())
        for category, text in changelog.extract_bullets(left_text)
        if changelog.normalize_bullet_text(text)
    }
    right_bullets = {
        (category, changelog.normalize_bullet_text(text).lower())
        for category, text in changelog.extract_bullets(right_text)
        if changelog.normalize_bullet_text(text)
    }
    return left_bullets == right_bullets and bool(left_bullets)


def _changelog_section_value(section):
    """Return a comparable numeric value for changelog section ordering."""
    try:
        return version_value(parse_version(section["version"]))
    except RuntimeError:
        # Non-semver headings such as Unreleased stay at the top when present.
        return float("inf")


def _insert_changelog_section_by_version(merged, section):
    """Insert section into merged so newer versions remain ahead of older ones."""
    new_value = _changelog_section_value(section)
    for index, existing in enumerate(merged):
        if new_value > _changelog_section_value(existing):
            merged.insert(index, section)
            return
    merged.append(section)


def reconcile_changelog_texts(ours_text, theirs_text):
    """Merge changelog histories section-by-section without losing either channel.

    Keeps beta (ours) ordering for shared versions when contents are compatible.
    Inserts main-only sections at the appropriate version position rather than
    appending them after all beta history. Incompatible same-version bodies fail
    instead of silently discarding either side.
    """
    changelog = _update_changelog()
    ours_preface, ours_sections = changelog.parse_changelog_sections(ours_text or "")
    theirs_preface, theirs_sections = changelog.parse_changelog_sections(theirs_text or "")
    preface = ours_preface if ours_preface.strip() else theirs_preface

    merged = []
    seen = set()
    theirs_by_version = {section["version"]: section for section in theirs_sections}

    for section in ours_sections:
        version = section["version"]
        other = theirs_by_version.get(version)
        if other is not None and not changelog_sections_compatible(section, other):
            raise RuntimeError(
                f"Incompatible CHANGELOG.md sections for version {version}; "
                "manual reconciliation is required."
            )
        merged.append(section)
        seen.add(version)

    for section in theirs_sections:
        if section["version"] in seen:
            continue
        _insert_changelog_section_by_version(merged, section)
        seen.add(section["version"])

    rebuilt = [preface.rstrip()]
    for section in merged:
        rebuilt.extend(["", section["text"]])
    return changelog.normalize_changelog("\n".join(rebuilt))


def _changelog_text_equivalent(left, right):
    """Compare changelog fragments after the writer's blank-line normalization."""
    def normalize(text):
        return re.sub(r"\n{3,}", "\n\n", (text or "").strip())

    return normalize(left) == normalize(right)


def _is_wholly_generated_compatibility_section(changelog, section):
    """Return True when section body is exactly a rendered compatibility note set."""
    bullets = changelog.extract_bullets(section.get("text", ""))
    if not bullets:
        return False

    entries = []
    for category, text in bullets:
        cleaned = changelog.normalize_bullet_text(text)
        if not cleaned or not changelog.is_compatibility_note(cleaned):
            return False
        entries.append({"category": category, "text": cleaned})

    rendered = changelog.render_section(
        section["version"],
        section.get("date") or "",
        entries,
    )
    return _changelog_text_equivalent(rendered, section.get("text", ""))


def assert_changelog_delta_is_generated_only(base_text, head_text, *, label):
    """Fail when a main-range CHANGELOG delta includes non-generated content.

    Preface and pre-existing release sections must remain unchanged (aside from
    the changelog writer's blank-line normalization). Newly added sections must
    be wholly generated compatibility content, not merely bullet-compatible.
    """
    changelog = _update_changelog()
    base_preface, base_sections = changelog.parse_changelog_sections(base_text or "")
    head_preface, head_sections = changelog.parse_changelog_sections(head_text or "")

    if not _changelog_text_equivalent(base_preface, head_preface):
        raise RuntimeError(
            f"{label} CHANGELOG.md modified the unversioned preface; "
            "refusing automatic synchronization."
        )

    base_by_version = {section["version"]: section for section in base_sections}
    head_by_version = {section["version"]: section for section in head_sections}

    for version, section in base_by_version.items():
        if version not in head_by_version:
            raise RuntimeError(
                f"{label} CHANGELOG.md removed section {version}; "
                "refusing automatic synchronization."
            )
        if not _changelog_text_equivalent(section["text"], head_by_version[version]["text"]):
            raise RuntimeError(
                f"{label} CHANGELOG.md modified existing section {version}; "
                "refusing automatic synchronization."
            )

    for version, section in head_by_version.items():
        if version in base_by_version:
            continue
        if not _is_wholly_generated_compatibility_section(changelog, section):
            raise RuntimeError(
                f"{label} CHANGELOG.md added non-generated content under {version}; "
                "refusing automatic synchronization."
            )


def assert_range_is_generated_metadata_only(repo_path, base_sha, head_sha, *, label):
    """Fail unless base...head only changes recognized generated metadata content.

    Path allowlisting alone is insufficient: unrelated edits inside README/TOC/
    CHANGELOG must also be rejected before synchronization.
    """
    paths = list_changed_paths(repo_path, base_sha, head_sha)
    if not paths:
        return True

    unexpected = [path for path in paths if path not in GENERATED_METADATA_PATH_SET]
    if unexpected:
        raise RuntimeError(
            f"{label} includes files outside generated game-version metadata: "
            f"{', '.join(unexpected)}"
        )

    for path in paths:
        base_text = read_git_blob(repo_path, base_sha, path) or ""
        head_text = read_git_blob(repo_path, head_sha, path) or ""
        if path.endswith(".toc"):
            if strip_toc_metadata_lines(base_text) != strip_toc_metadata_lines(head_text):
                raise RuntimeError(
                    f"{label} changes non-metadata content in {path}; "
                    "refusing automatic synchronization."
                )
        elif path == "README.md":
            if strip_readme_badge_lines(base_text) != strip_readme_badge_lines(head_text):
                raise RuntimeError(
                    f"{label} changes README.md content outside generated badges; "
                    "refusing automatic synchronization."
                )
        elif path == "CHANGELOG.md":
            assert_changelog_delta_is_generated_only(
                base_text,
                head_text,
                label=label,
            )
        else:
            raise RuntimeError(f"{label} touched unsupported metadata path {path}")
    return True


def range_only_touches_generated_metadata(repo_path, base_sha, head_sha):
    """Return True when base...head only modifies recognized generated metadata."""
    try:
        assert_range_is_generated_metadata_only(
            repo_path,
            base_sha,
            head_sha,
            label="Divergent main range",
        )
    except RuntimeError:
        return False
    return True


def identify_sync_main_sha(repo_path, *, main_sha, beta_sha, main_update_needed):
    """Return (sync_needed, sync_main_sha, reason) for main→beta history sync.

    When main still needs an update in this run, sync is required after that push
    and sync_main_sha is resolved later from the update-main job output.
    When main is already current, sync the captured main tip only if it is not yet
    an ancestor of beta and the divergent main range is metadata-only.
    """
    if main_update_needed:
        return True, "", "main update will require synchronizing the new main commit into beta"

    if git_is_ancestor(repo_path, main_sha, beta_sha):
        return False, "", "main tip is already an ancestor of beta"

    merge_base = git_merge_base(repo_path, main_sha, beta_sha)
    assert_range_is_generated_metadata_only(
        repo_path,
        merge_base,
        main_sha,
        label="Main tip is not in beta ancestry, but the divergent main range",
    )
    return True, main_sha, "main game-version commit is missing from beta ancestry"


def apply_channel_metadata(
    repo_path,
    *,
    channel,
    interface,
    version,
    game_version,
    ensure_beta_concurrency=False,
    update_changelog=True,
):
    """Apply TOC, README, and optional compatibility changelog updates in repo_path."""
    repo_path = Path(repo_path)
    toc_path = repo_path / "SpectrumFederation" / "SpectrumFederation.toc"
    update_packaged_tocs(toc_path, str(interface), version)
    update_readme_badges(repo_path / "README.md", version, interface, channel)

    if update_changelog:
        from datetime import datetime, timezone

        changelog = _update_changelog()
        previous_cwd = Path.cwd()
        try:
            os.chdir(repo_path)
            changelog.apply_compatibility_changelog(
                version,
                game_version,
                str(interface),
                datetime.now(timezone.utc).date().isoformat(),
            )
        finally:
            os.chdir(previous_cwd)

    if ensure_beta_concurrency and channel == "beta":
        workflow = repo_path / ".github" / "workflows" / "post-merge-beta.yml"
        if workflow.exists():
            ensure_release_channels_concurrency(workflow)


def _stage_paths(repo_path, paths):
    if not paths:
        return
    subprocess.run(["git", "-C", str(repo_path), "add", "--", *paths], check=True)


def resolve_generated_metadata_conflicts(
    repo_path,
    *,
    beta_interface,
    beta_version,
):
    """Resolve merge conflicts only for recognized generated metadata files."""
    repo_path = Path(repo_path)
    conflicted = list_unmerged_paths(repo_path)
    if not conflicted:
        return []

    unexpected = [path for path in conflicted if path not in GENERATED_METADATA_PATH_SET]
    if unexpected:
        details = ", ".join(unexpected)
        raise RuntimeError(
            "Merge conflicts outside generated game-version metadata; aborting before push. "
            f"Unexpected paths: {details}. Manual intervention is required."
        )

    resolved = []
    for rel_path in conflicted:
        ours = read_git_blob(repo_path, ":2", rel_path)
        theirs = read_git_blob(repo_path, ":3", rel_path)
        if ours is None or theirs is None:
            raise RuntimeError(
                f"Unable to read both merge stages for conflicted file {rel_path}; "
                "manual intervention is required."
            )

        target = repo_path / rel_path
        if rel_path.endswith(".toc"):
            if strip_toc_metadata_lines(ours) != strip_toc_metadata_lines(theirs):
                raise RuntimeError(
                    f"TOC conflict in {rel_path} includes non-metadata edits; "
                    "refusing automatic resolution."
                )
            # Prefer beta stage body, then stamp planned beta Interface/Version.
            target.write_text(ours, encoding="utf-8")
            update_toc(target, str(beta_interface), beta_version)
        elif rel_path == "README.md":
            if strip_readme_badge_lines(ours) != strip_readme_badge_lines(theirs):
                raise RuntimeError(
                    "README.md conflict includes edits outside generated badges; "
                    "refusing automatic resolution."
                )
            target.write_text(ours, encoding="utf-8")
            update_readme_badges(target, beta_version, beta_interface, "beta")
        elif rel_path == "CHANGELOG.md":
            target.write_text(reconcile_changelog_texts(ours, theirs), encoding="utf-8")
        else:
            raise RuntimeError(f"Unsupported conflicted metadata path: {rel_path}")

        _stage_paths(repo_path, [rel_path])
        resolved.append(rel_path)

    remaining = list_unmerged_paths(repo_path)
    if remaining:
        raise RuntimeError(
            "Generated-metadata conflict resolution left unresolved paths: "
            + ", ".join(remaining)
        )
    return resolved


def integrate_main_into_beta(
    repo_path,
    *,
    main_sha,
    beta_interface,
    beta_version,
    game_version,
    beta_update_needed,
    commit=True,
    commit_message=None,
):
    """Merge main_sha into the current beta checkout and finalize beta metadata.

    Performs one in-progress merge, resolves only generated-metadata conflicts,
    applies the planned beta metadata when needed, and optionally creates a single
    merge commit. Does not push.
    """
    repo_path = Path(repo_path)
    if git_is_ancestor(repo_path, main_sha, "HEAD"):
        if beta_update_needed:
            apply_channel_metadata(
                repo_path,
                channel="beta",
                interface=beta_interface,
                version=beta_version,
                game_version=game_version,
                ensure_beta_concurrency=True,
                update_changelog=True,
            )
            staged = [*packaged_toc_relpaths(), "README.md", "CHANGELOG.md"]
            workflow = repo_path / ".github" / "workflows" / "post-merge-beta.yml"
            if workflow.exists():
                staged.append(".github/workflows/post-merge-beta.yml")
            existing_staged = [path for path in staged if (repo_path / path).exists()]
            _stage_paths(repo_path, existing_staged)
            if commit:
                message = commit_message or (
                    f"chore: bump Interface to {beta_interface} and version to {beta_version} [skip ci]"
                )
                status = subprocess.run(
                    ["git", "-C", str(repo_path), "status", "--porcelain"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                if status:
                    subprocess.run(
                        ["git", "-C", str(repo_path), "commit", "-m", message],
                        check=True,
                        capture_output=True,
                        text=True,
                    )
        return {
            "synced": False,
            "reason": "main_sha already an ancestor of HEAD",
            "resolved_paths": [],
            "commit_sha": resolve_git_sha(repo_path, "HEAD"),
        }

    merge_base = git_merge_base(repo_path, main_sha, "HEAD")
    assert_range_is_generated_metadata_only(
        repo_path,
        merge_base,
        main_sha,
        label="Refusing to synchronize main into beta because the main range",
    )

    merge = subprocess.run(
        [
            "git",
            "-C",
            str(repo_path),
            "merge",
            "--no-ff",
            "--no-commit",
            main_sha,
            "-m",
            commit_message
            or (
                f"{HISTORY_SYNC_COMMIT_PREFIX} [skip ci]"
                if not beta_update_needed
                else f"chore: bump Interface to {beta_interface} and version to {beta_version} [skip ci]"
            ),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if merge.returncode not in (0, 1):
        raise RuntimeError(
            f"git merge of {main_sha} failed:\n{merge.stdout}\n{merge.stderr}"
        )

    resolved_paths = []
    if merge.returncode == 1:
        resolved_paths = resolve_generated_metadata_conflicts(
            repo_path,
            beta_interface=beta_interface,
            beta_version=beta_version,
        )

    # Always stamp planned beta TOC/README onto the final tree so beta is never
    # left with stable values from main, even when Git auto-merged. Only write a
    # beta compatibility changelog section when a beta version bump is planned.
    apply_channel_metadata(
        repo_path,
        channel="beta",
        interface=beta_interface,
        version=beta_version,
        game_version=game_version,
        ensure_beta_concurrency=beta_update_needed,
        update_changelog=beta_update_needed,
    )
    staged = [*packaged_toc_relpaths(), "README.md", "CHANGELOG.md"]
    workflow = repo_path / ".github" / "workflows" / "post-merge-beta.yml"
    if workflow.exists() and beta_update_needed:
        staged.append(".github/workflows/post-merge-beta.yml")
    existing_staged = [path for path in staged if (repo_path / path).exists()]
    _stage_paths(repo_path, existing_staged)

    if not commit:
        return {
            "synced": True,
            "reason": "merge prepared without commit",
            "resolved_paths": resolved_paths,
            "commit_sha": "",
        }

    message = commit_message
    if not message:
        if beta_update_needed:
            message = (
                f"chore: bump Interface to {beta_interface} and version to {beta_version} [skip ci]"
            )
        else:
            message = f"{HISTORY_SYNC_COMMIT_PREFIX} [skip ci]"

    # Completing an in-progress merge reuses MERGE_HEAD; otherwise create a normal commit.
    merge_head = repo_path / ".git" / "MERGE_HEAD"
    if merge_head.exists():
        subprocess.run(
            ["git", "-C", str(repo_path), "commit", "-m", message],
            check=True,
            capture_output=True,
            text=True,
        )
    else:
        status = subprocess.run(
            ["git", "-C", str(repo_path), "status", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if status:
            subprocess.run(
                ["git", "-C", str(repo_path), "commit", "-m", message],
                check=True,
                capture_output=True,
                text=True,
            )

    commit_sha = resolve_git_sha(repo_path, "HEAD")
    if not git_is_ancestor(repo_path, main_sha, commit_sha):
        raise RuntimeError(
            f"Integration commit {commit_sha} does not contain main commit {main_sha}"
        )
    return {
        "synced": True,
        "reason": "merged main into beta and finalized metadata",
        "resolved_paths": resolved_paths,
        "commit_sha": commit_sha,
    }


def simulate_channel_integration(
    repo_path,
    plan,
    *,
    work_dir,
    game_version=None,
):
    """Simulate main update + main→beta sync + beta finalize without touching remotes.

    Uses a local clone under work_dir. Returns a result dict for Actions summaries.
    """
    import shutil
    import tempfile

    repo_path = Path(repo_path).resolve()
    work_dir = Path(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    sim_repo = Path(tempfile.mkdtemp(prefix="sf-game-version-sim-", dir=str(work_dir)))

    try:
        subprocess.run(
            ["git", "clone", "--local", str(repo_path), str(sim_repo)],
            check=True,
            capture_output=True,
            text=True,
        )
        git_config(sim_repo)

        main_sha = plan["main_sha"]
        beta_sha = plan["beta_sha"]
        interface = str(plan["interface"])
        game_version = game_version or plan.get("game_version") or plan.get("requested_version")
        main_target = plan["main_target_version"]
        beta_target = plan["beta_target_version"]

        subprocess.run(
            ["git", "-C", str(sim_repo), "checkout", "--force", main_sha],
            check=True,
            capture_output=True,
            text=True,
        )
        simulated_main_sha = main_sha
        if plan.get("main_update_needed"):
            apply_channel_metadata(
                sim_repo,
                channel="main",
                interface=interface,
                version=main_target,
                game_version=game_version,
            )
            _stage_paths(
                sim_repo,
                [*packaged_toc_relpaths(), "README.md", "CHANGELOG.md"],
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(sim_repo),
                    "commit",
                    "-m",
                    f"chore: bump Interface to {interface} and version to {main_target} [skip ci]",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            simulated_main_sha = resolve_git_sha(sim_repo, "HEAD")

        sync_needed = bool(plan.get("sync_needed"))
        if plan.get("main_update_needed"):
            sync_needed = True
        elif not sync_needed:
            sync_needed = not git_is_ancestor(sim_repo, simulated_main_sha, beta_sha)

        subprocess.run(
            ["git", "-C", str(sim_repo), "checkout", "--force", "-B", "sim-beta", beta_sha],
            check=True,
            capture_output=True,
            text=True,
        )

        # Preserve a beta-only marker path check when present in tests/fixtures.
        beta_only_probe = None
        probe_path = sim_repo / "SpectrumFederation" / ".sf-beta-only-probe"
        if probe_path.exists():
            beta_only_probe = probe_path.read_text(encoding="utf-8")

        integration = {"synced": False, "resolved_paths": [], "commit_sha": beta_sha}
        if sync_needed or plan.get("beta_update_needed"):
            if sync_needed:
                integration = integrate_main_into_beta(
                    sim_repo,
                    main_sha=simulated_main_sha,
                    beta_interface=interface,
                    beta_version=beta_target,
                    game_version=game_version,
                    beta_update_needed=bool(plan.get("beta_update_needed")),
                    commit=True,
                )
            elif plan.get("beta_update_needed"):
                apply_channel_metadata(
                    sim_repo,
                    channel="beta",
                    interface=interface,
                    version=beta_target,
                    game_version=game_version,
                    ensure_beta_concurrency=True,
                )
                _stage_paths(
                    sim_repo,
                    [*packaged_toc_relpaths(), "README.md", "CHANGELOG.md"],
                )
                subprocess.run(
                    [
                        "git",
                        "-C",
                        str(sim_repo),
                        "commit",
                        "-m",
                        f"chore: bump Interface to {interface} and version to {beta_target} [skip ci]",
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                integration = {
                    "synced": False,
                    "resolved_paths": [],
                    "commit_sha": resolve_git_sha(sim_repo, "HEAD"),
                }

        final_sha = resolve_git_sha(sim_repo, "HEAD")
        if sync_needed and not git_is_ancestor(sim_repo, simulated_main_sha, final_sha):
            raise RuntimeError("Simulation failed: main commit is not an ancestor of beta")

        main_iface, main_ver = read_toc_fields_from_git(
            sim_repo, simulated_main_sha, "SpectrumFederation/SpectrumFederation.toc"
        )
        beta_iface, beta_ver = read_toc_fields_from_git(
            sim_repo, final_sha, "SpectrumFederation/SpectrumFederation.toc"
        )
        if main_iface != interface or main_ver != main_target:
            raise RuntimeError(
                f"Simulation main metadata mismatch: expected {interface}/{main_target}, "
                f"found {main_iface}/{main_ver}"
            )
        if beta_iface != interface or beta_ver != beta_target:
            raise RuntimeError(
                f"Simulation beta metadata mismatch: expected {interface}/{beta_target}, "
                f"found {beta_iface}/{beta_ver}"
            )

        changelog_text = read_git_blob(sim_repo, final_sha, "CHANGELOG.md") or ""
        if plan.get("main_update_needed") and f"## [{main_target}]" not in changelog_text:
            raise RuntimeError(f"Simulation changelog missing main section {main_target}")
        if plan.get("beta_update_needed") and f"## [{beta_target}]" not in changelog_text:
            raise RuntimeError(f"Simulation changelog missing beta section {beta_target}")

        if beta_only_probe is not None:
            current_probe = read_git_blob(
                sim_repo, final_sha, "SpectrumFederation/.sf-beta-only-probe"
            )
            if current_probe != beta_only_probe:
                raise RuntimeError("Simulation lost beta-only addon content")

        result = {
            "ok": True,
            "sync_needed": sync_needed,
            "simulated_main_sha": simulated_main_sha,
            "simulated_beta_sha": final_sha,
            "resolved_paths": integration.get("resolved_paths") or [],
            "main_version": main_ver,
            "beta_version": beta_ver,
            "main_interface": main_iface,
            "beta_interface": beta_iface,
        }
        return result
    finally:
        shutil.rmtree(sim_repo, ignore_errors=True)


def is_beta_semver(version_raw):
    """Return True when version is X.Y.Z-beta.N."""
    info = parse_version(version_raw)
    return info.kind == "semver" and info.label is not None and info.pre is not None


def github_release_exists(version, repo, token):
    """Return True/False when GitHub already has release tag v{version}, or None if unverifiable."""
    release = fetch_github_release(version, repo, token)
    if release is None and (not repo or not token):
        return None
    return release is not None


def fetch_github_release(version, repo, token):
    """Return the GitHub release JSON for v{version}, or None when missing/unverifiable."""
    if not repo or not token:
        return None

    tag = f"v{version}"
    url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    req = request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with request.urlopen(req, timeout=30) as resp:
            payload = resp.read().decode("utf-8")
            return json.loads(payload)
    except error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise RuntimeError(f"GitHub release lookup failed for {tag}: HTTP {exc.code}") from exc
    except (error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"GitHub release lookup failed for {tag}: {exc}") from exc


def list_remote_release_tags(repo_path):
    """Return tag names like v1.5.8 from origin, without the refs/tags/ prefix."""
    result = subprocess.run(
        ["git", "-C", str(repo_path), "ls-remote", "--tags", "origin"],
        check=True,
        capture_output=True,
        text=True,
    )
    tags = set()
    for line in result.stdout.splitlines():
        if "\t" not in line:
            continue
        _sha, ref = line.split("\t", 1)
        if ref.endswith("^{}"):
            continue
        if ref.startswith("refs/tags/"):
            tags.add(ref[len("refs/tags/") :])
    return tags


def version_tag_occupied(version_raw, occupied_tags):
    """Return True when v{version} is already present in occupied_tags."""
    return f"v{version_raw}" in occupied_tags


def avoid_stable_tag_collision(version_info, occupied_tags):
    """Bump a stable X.Y.Z until vX.Y.Z is free."""
    candidate = version_info
    for _ in range(100):
        if not version_tag_occupied(candidate.raw, occupied_tags):
            return candidate
        candidate = bump_main_version(candidate)
    raise RuntimeError(f"Could not find a free stable tag after {version_info.raw}")


def avoid_beta_tag_collision(version_info, occupied_tags):
    """Bump a beta prerelease until its tag is free."""
    candidate = version_info
    for _ in range(200):
        if not version_tag_occupied(candidate.raw, occupied_tags):
            return candidate
        candidate = bump_beta_prerelease(candidate)
    raise RuntimeError(f"Could not find a free beta tag after {version_info.raw}")


def plan_branch_action(
    *,
    channel,
    interface_matches,
    version_raw,
    repo,
    token,
    retry_publication=False,
):
    """Return update, publish, or none for one branch.

    - update: Interface must change; version will bump before publish
    - publish: Interface already correct; safe channel-matched publish/retry
    - none: no mutation and no publish (including stable versions on beta)

    When retry_publication is true and a channel-matched GitHub release already
    exists, return publish so an idempotent publisher can recover downstream
    CurseForge/Wago failures without bumping TOC versions.
    """
    if channel not in {"main", "beta"}:
        raise RuntimeError(f"Unsupported channel '{channel}'")

    if not interface_matches:
        return "update"

    version_is_beta = is_beta_semver(version_raw)
    if channel == "beta" and not version_is_beta:
        # Already-current stable TOC on beta must never publish over a stable release.
        return "none"
    if channel == "main" and version_is_beta:
        return "none"

    release = fetch_github_release(version_raw, repo, token)
    if release is None and (not repo or not token):
        # Unverifiable without credentials: do not invent a publish.
        return "none"
    if release is None:
        # Channel-matched Interface with no GitHub release: recover a partial publish.
        return "publish"

    release_is_prerelease = bool(release.get("prerelease"))
    if channel == "main" and release_is_prerelease:
        raise RuntimeError(
            f"GitHub tag v{version_raw} is a prerelease; refusing to treat it as a stable main release."
        )
    if channel == "beta" and not release_is_prerelease:
        raise RuntimeError(
            f"GitHub tag v{version_raw} is a stable release; refusing to publish it from beta."
        )

    if retry_publication:
        return "publish"

    # Matching GitHub release already exists: ordinary runs stay no-ops.
    return "none"


def assert_no_conflicting_workflow_runs(repo, token, *, current_run_id=None):
    """Fail when promote, rollback, post-merge beta, or another game-version run is active."""
    if not repo or not token:
        raise RuntimeError(
            "GITHUB_TOKEN is required to check for conflicting workflow runs before mutation."
        )

    conflicting_names = {
        "Post-Merge Beta",
        "Promote Beta to Main",
        "Rollback Release",
        "Update WoW Game Version",
    }
    url = (
        f"https://api.github.com/repos/{repo}/actions/runs"
        f"?status=in_progress&per_page=50"
    )
    req = request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as exc:
        raise RuntimeError(f"Failed to list workflow runs: HTTP {exc.code}") from exc
    except (error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Failed to list workflow runs: {exc}") from exc

    blockers = []
    for run in payload.get("workflow_runs", []):
        run_id = run.get("id")
        if current_run_id is not None and str(run_id) == str(current_run_id):
            continue
        name = run.get("name") or ""
        if name in conflicting_names:
            blockers.append(f"{name} #{run.get('run_number')} ({run.get('html_url')})")

    # Also catch queued runs that would start once the current lock releases.
    queued_url = (
        f"https://api.github.com/repos/{repo}/actions/runs"
        f"?status=queued&per_page=50"
    )
    req = request.Request(
        queued_url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with request.urlopen(req, timeout=30) as resp:
            queued_payload = json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as exc:
        raise RuntimeError(f"Failed to list queued workflow runs: HTTP {exc.code}") from exc
    except (error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Failed to list queued workflow runs: {exc}") from exc

    for run in queued_payload.get("workflow_runs", []):
        run_id = run.get("id")
        if current_run_id is not None and str(run_id) == str(current_run_id):
            continue
        name = run.get("name") or ""
        if name in conflicting_names:
            blockers.append(f"{name} #{run.get('run_number')} queued ({run.get('html_url')})")

    if blockers:
        details = "; ".join(blockers)
        raise RuntimeError(
            "Conflicting release workflow activity detected. Wait for it to finish, then re-run. "
            f"Active/queued: {details}"
        )


def ensure_release_channels_concurrency(workflow_path):
    """Rewrite concurrency to `release-channels` with `queue: max`.

    Older beta tips may still use `group: beta-release` and omit `queue: max`.
    Without `queue: max`, GitHub keeps only one pending run per group and
    cancels older waiting releases when another release workflow queues.
    """
    path = Path(workflow_path)
    content = path.read_text(encoding="utf-8")
    updated = re.sub(
        r"(?m)^(\s*group:\s*)beta-release\s*$",
        r"\1release-channels",
        content,
    )

    def _ensure_queue(match):
        indent = match.group("indent")
        return f"{indent}group: release-channels\n{indent}queue: max\n"

    updated = re.sub(
        r"(?m)^(?P<indent>\s*)group:\s*release-channels\s*\n"
        r"(?:(?P=indent)queue:\s*\S+\s*\n)?",
        _ensure_queue,
        updated,
    )
    if updated != content:
        path.write_text(updated, encoding="utf-8")
        return True
    return False


def materialize_workflow_helpers(repo_path, workflow_sha, destination):
    """Copy pinned automation helpers from workflow_sha into destination.

    The Update WoW Game Version workflow must run helpers from the dispatched
    main/workflow commit even when the working tree is checked out at an older
    beta tip that does not yet contain those helpers.
    """
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    helpers = (
        "wow_interface_sync.py",
        "update_changelog.py",
        "publish_release.py",
        "validate_packaging.py",
        "blizzard_api.py",
        "classify_promotion_scope.py",
        "check_duplicate_release.py",
    )
    materialized = []
    for name in helpers:
        rel = f".github/scripts/{name}"
        probe = subprocess.run(
            ["git", "-C", str(repo_path), "cat-file", "-e", f"{workflow_sha}:{rel}"],
            check=False,
            capture_output=True,
        )
        if probe.returncode != 0:
            continue
        content = subprocess.run(
            ["git", "-C", str(repo_path), "show", f"{workflow_sha}:{rel}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        target = destination / name
        target.write_text(content, encoding="utf-8")
        materialized.append(str(target))
    required = {
        "wow_interface_sync.py",
        "update_changelog.py",
        "publish_release.py",
        "validate_packaging.py",
        "blizzard_api.py",
    }
    present = {Path(path).name for path in materialized}
    missing = sorted(required - present)
    if missing:
        raise RuntimeError(
            f"Workflow commit {workflow_sha} is missing required helpers: {', '.join(missing)}"
        )
    return materialized


def build_update_plan(
    *,
    requested,
    live_game_version,
    live_interface,
    main_interface,
    main_version_raw,
    beta_interface,
    beta_version_raw,
    main_sha,
    beta_sha,
    repo=None,
    token=None,
    occupied_tags=None,
    retry_publication=False,
    repo_path=None,
):
    """Build the immutable plan consumed by the workflow."""
    target_interface = verify_requested_matches_live(
        requested,
        live_interface,
        live_game_version=live_game_version,
    )
    target_interface_str = str(target_interface)

    main_version = parse_version(main_version_raw)
    beta_version = parse_version(beta_version_raw)
    if main_version.kind != "semver" or beta_version.kind != "semver":
        raise RuntimeError("Main and beta TOC versions must use semver")
    if main_version.label is not None or main_version.pre is not None:
        raise RuntimeError(f"Main TOC version must be stable X.Y.Z, got {main_version_raw}")

    main_update_needed = main_interface != target_interface_str
    # Matching stable TOC on main and beta after promotion is normal and must not
    # invent a beta prerelease. Only force a beta version advance when a real main
    # compatibility bump would catch or pass beta's current train.
    provisional_main = bump_main_version(main_version) if main_update_needed else main_version
    beta_caught_by_main = (
        main_update_needed
        and version_value(beta_version) <= version_value(provisional_main)
    )
    beta_update_needed = beta_interface != target_interface_str or beta_caught_by_main
    occupied_tags = set(occupied_tags or ())

    new_main_version, new_beta_version, beta_ahead = compute_updated_versions(
        main_version,
        beta_version,
        main_update_needed,
        beta_update_needed=beta_update_needed,
    )

    if main_update_needed:
        new_main_version = avoid_stable_tag_collision(new_main_version, occupied_tags)
        occupied_tags.add(f"v{new_main_version.raw}")
    if beta_update_needed:
        # Recompute beta against the collision-adjusted main train when needed.
        if train_tuple(beta_version) > train_tuple(new_main_version):
            new_beta_version = bump_beta_prerelease(beta_version)
        else:
            new_beta_version = next_beta_after_stable(new_main_version)
        new_beta_version = avoid_beta_tag_collision(new_beta_version, occupied_tags)
        if version_value(new_beta_version) <= version_value(new_main_version):
            raise RuntimeError(
                f"Computed beta version {new_beta_version.raw} is not ahead of "
                f"main version {new_main_version.raw}"
            )
        beta_ahead = True

    main_target_version = new_main_version.raw if main_update_needed else main_version.raw
    beta_target_version = new_beta_version.raw if beta_update_needed else beta_version.raw

    main_action = plan_branch_action(
        channel="main",
        interface_matches=not main_update_needed,
        version_raw=main_target_version,
        repo=repo,
        token=token,
        retry_publication=retry_publication,
    )
    beta_action = plan_branch_action(
        channel="beta",
        interface_matches=not beta_update_needed,
        version_raw=beta_target_version,
        repo=repo,
        token=token,
        retry_publication=retry_publication,
    )

    sync_needed = False
    sync_main_sha = ""
    sync_reason = "not evaluated"
    if repo_path is not None:
        sync_needed, sync_main_sha, sync_reason = identify_sync_main_sha(
            repo_path,
            main_sha=main_sha,
            beta_sha=beta_sha,
            main_update_needed=main_update_needed,
        )
    elif main_update_needed:
        sync_needed = True
        sync_reason = "main update will require synchronizing the new main commit into beta"

    if retry_publication and sync_needed:
        raise RuntimeError(
            "retry_publication cannot mutate branches, but main→beta history sync is still "
            f"required ({sync_reason}). Re-run without retry_publication to complete "
            "synchronization first, then retry publication."
        )

    any_work = (
        main_action in {"update", "publish"}
        or beta_action in {"update", "publish"}
        or sync_needed
    )
    return {
        "requested_version": requested["normalized"],
        "game_version": requested["normalized"],
        "live_game_version": live_game_version or "",
        "interface": target_interface_str,
        "main_sha": main_sha,
        "beta_sha": beta_sha,
        "main_current_interface": main_interface,
        "beta_current_interface": beta_interface,
        "main_current_version": main_version.raw,
        "beta_current_version": beta_version.raw,
        "main_target_version": main_target_version,
        "beta_target_version": beta_target_version,
        "main_update_needed": main_update_needed,
        "beta_update_needed": beta_update_needed,
        "main_action": main_action,
        "beta_action": beta_action,
        "beta_ahead": beta_ahead,
        "any_toc_update": main_update_needed or beta_update_needed,
        "sync_needed": sync_needed,
        "sync_main_sha": sync_main_sha,
        "sync_reason": sync_reason,
        "beta_branch_mutation": beta_update_needed or sync_needed,
        "any_work": any_work,
    }


def update_readme_badges(readme_path, version, interface, track):
    """Update Version/Interface/Track shields.io badges in README.md."""
    import blizzard_api

    path = Path(readme_path)
    content = path.read_text(encoding="utf-8")
    interface_display = blizzard_api.interface_to_display(str(interface))
    version_escaped = str(version).replace("-", "--")
    track_value = "Beta" if track == "beta" else "Retail"

    updated = re.sub(
        r"badge/Version-[^)]*-brightgreen",
        f"badge/Version-{version_escaped}-brightgreen",
        content,
    )
    updated = re.sub(
        r"badge/Interface-[^-]*-",
        f"badge/Interface-{interface_display}-",
        updated,
    )
    updated = re.sub(
        r"badge/Track-[^-]*-",
        f"badge/Track-{track_value}-",
        updated,
    )
    if updated != content:
        path.write_text(updated, encoding="utf-8")
        return True
    return False


def write_step_summary(plan, *, dry_run=False, simulation=None):
    """Append a human-readable plan summary for GitHub Actions."""
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return

    title = "Update WoW Game Version (dry run)" if dry_run else "Update WoW Game Version plan"
    lines = [
        f"## {title}",
        "",
        f"- Requested game version: `{plan['requested_version']}`",
        f"- Target Interface: `{plan['interface']}`",
        f"- Live Retail: `{plan['live_game_version'] or 'unknown'}`",
        f"- Main SHA: `{plan['main_sha']}`",
        f"- Beta SHA: `{plan['beta_sha']}`",
        f"- Retry publication: `{'true' if plan.get('retry_publication') else 'false'}`",
        f"- Main→beta sync needed: `{'true' if plan.get('sync_needed') else 'false'}`",
        f"- Sync reason: {plan.get('sync_reason') or 'n/a'}",
        f"- Sync main SHA: `{plan.get('sync_main_sha') or '(from update-main push)'}`",
        "",
        "| Branch | Interface | Version | Action |",
        "| --- | --- | --- | --- |",
        (
            f"| main | {plan['main_current_interface']} → {plan['interface']} | "
            f"{plan['main_current_version']} → {plan['main_target_version']} | "
            f"{plan['main_action']} |"
        ),
        (
            f"| beta | {plan['beta_current_interface']} → {plan['interface']} | "
            f"{plan['beta_current_version']} → {plan['beta_target_version']} | "
            f"{plan['beta_action']} |"
        ),
        "",
    ]
    if simulation is not None:
        lines.extend(
            [
                "### Integration simulation",
                "",
                f"- Result: `{'ok' if simulation.get('ok') else 'failed'}`",
                f"- Simulated main SHA: `{simulation.get('simulated_main_sha', '')}`",
                f"- Simulated beta SHA: `{simulation.get('simulated_beta_sha', '')}`",
                (
                    "- Resolved metadata paths: "
                    f"`{', '.join(simulation.get('resolved_paths') or []) or '(none)'}`"
                ),
                "",
            ]
        )
    if dry_run:
        lines.append("Dry run only: no branch mutations or publishing were performed.")
        lines.append("")
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def _emit_plan_outputs(plan):
    """Write plan fields to GITHUB_OUTPUT for workflow jobs."""
    bool_keys = (
        "main_update_needed",
        "beta_update_needed",
        "beta_ahead",
        "any_toc_update",
        "any_work",
        "retry_publication",
        "sync_needed",
        "beta_branch_mutation",
    )
    for key, value in plan.items():
        if key in bool_keys:
            write_output(key, "true" if value else "false")
        else:
            write_output(key, value)


def run_plan_mode(args):
    """Plan main/beta updates for a requested human-readable Retail version."""
    requested = parse_human_game_version(args.requested_version)
    print(f"[sync] Requested game version: {requested['normalized']} (Interface {requested['interface']})")

    live_game_version, live_interface, resolver_strategy = resolve_live_interface(
        args.region,
        allow_network=not args.no_network,
    )
    print(f"[sync] Resolver strategy: {resolver_strategy}")
    if live_game_version:
        print(f"[sync] Live game version: {live_game_version}")
    else:
        print("[sync] Live game version: unknown (resolved without game version source)")
    print(f"[sync] Live Interface: {live_interface}")

    repo_path = Path(args.repo_path or ".")
    main_ref = args.main_ref
    beta_ref = args.beta_ref
    main_sha = resolve_git_sha(repo_path, main_ref)
    beta_sha = resolve_git_sha(repo_path, beta_ref)
    main_interface, main_version_raw = read_toc_fields_from_git(repo_path, main_ref, args.toc_path)
    beta_interface, beta_version_raw = read_toc_fields_from_git(repo_path, beta_ref, args.toc_path)
    occupied_tags = list_remote_release_tags(repo_path)
    print(f"[sync] Remote release tags considered for collisions: {len(occupied_tags)}")

    plan = build_update_plan(
        requested=requested,
        live_game_version=live_game_version,
        live_interface=live_interface,
        main_interface=main_interface,
        main_version_raw=main_version_raw,
        beta_interface=beta_interface,
        beta_version_raw=beta_version_raw,
        main_sha=main_sha,
        beta_sha=beta_sha,
        repo=os.environ.get("GITHUB_REPOSITORY"),
        token=os.environ.get("GITHUB_TOKEN"),
        occupied_tags=occupied_tags,
        retry_publication=bool(args.retry_publication),
        repo_path=repo_path,
    )
    plan["resolver_strategy"] = resolver_strategy
    plan["retry_publication"] = bool(args.retry_publication)

    simulation = None
    if args.simulate_integration or args.dry_run:
        work_dir = Path(args.simulation_work_dir or "/tmp/sf-game-version-sim")
        simulation = simulate_channel_integration(
            repo_path,
            plan,
            work_dir=work_dir,
            game_version=plan["game_version"],
        )
        plan["simulation_ok"] = True
        print(json.dumps({"simulation": simulation}, indent=2, sort_keys=True))

    print(json.dumps(plan, indent=2, sort_keys=True))
    _emit_plan_outputs(plan)
    write_step_summary(plan, dry_run=args.dry_run, simulation=simulation)
    return 0


def main():
    parser = argparse.ArgumentParser(description="Sync WoW Interface and addon versions across branches")
    parser.add_argument("--toc-path", default="SpectrumFederation/SpectrumFederation.toc", help="Path to TOC file")
    parser.add_argument("--main-path", help="Path to working tree for main branch")
    parser.add_argument("--beta-path", help="Path to working tree for beta branch")
    parser.add_argument("--main-branch", default="main", help="Main branch name (default: main)")
    parser.add_argument("--beta-branch", default="beta", help="Beta branch name (default: beta)")
    parser.add_argument("--addon-name", default="SpectrumFederation", help="Addon name for logging")
    parser.add_argument("--region", default="us", help="Patch region to query (default: us)")
    parser.add_argument("--dry-run", action="store_true", help="Resolve/plan without committing or publishing")
    parser.add_argument("--no-network", action="store_true", help="Skip network strategies and only allow manual override")
    parser.add_argument(
        "--commit-and-push",
        action="store_true",
        help="Commit and push TOC changes directly from this script (disabled by default)",
    )
    parser.add_argument(
        "--requested-version",
        help="Human-readable Retail version for the manual workflow (for example 12.1.5)",
    )
    parser.add_argument(
        "--plan",
        action="store_true",
        help="Emit a main/beta update plan for the requested version without mutating branches",
    )
    parser.add_argument(
        "--retry-publication",
        action="store_true",
        help=(
            "When Interface already matches, republish the existing channel-matched "
            "version through the idempotent publisher (downstream CF/Wago recovery)"
        ),
    )
    parser.add_argument("--repo-path", default=".", help="Repository path for --plan git reads")
    parser.add_argument("--main-ref", default="origin/main", help="Git ref for main when planning")
    parser.add_argument("--beta-ref", default="origin/beta", help="Git ref for beta when planning")
    parser.add_argument(
        "--verify-sha",
        metavar="SHA",
        help="With --main-ref/--beta-ref, verify the ref still equals this SHA and exit",
    )
    parser.add_argument(
        "--verify-ref",
        help="Git ref to verify against --verify-sha",
    )
    parser.add_argument(
        "--apply-toc-version",
        metavar="VERSION",
        help="Update packaged TOCs in the current checkout to --apply-interface/--apply-toc-version",
    )
    parser.add_argument(
        "--apply-interface",
        metavar="INTERFACE",
        help="Interface value used with --apply-toc-version",
    )
    parser.add_argument(
        "--update-readme",
        metavar="TRACK",
        choices=("main", "beta"),
        help="Update README badges for TRACK using --apply-interface and --apply-toc-version",
    )
    parser.add_argument(
        "--materialize-helpers",
        metavar="DIR",
        help="Copy pinned helpers from --workflow-sha into DIR and exit",
    )
    parser.add_argument(
        "--workflow-sha",
        help="Commit SHA that owns the automation helpers to materialize",
    )
    parser.add_argument(
        "--assert-no-conflicts",
        action="store_true",
        help="Fail when a conflicting release workflow run is in progress or queued",
    )
    parser.add_argument(
        "--current-run-id",
        help="GitHub Actions run id to ignore while checking conflicting runs",
    )
    parser.add_argument(
        "--ensure-beta-release-concurrency",
        metavar="PATH",
        help="Rewrite post-merge-beta concurrency group to release-channels when outdated",
    )
    parser.add_argument(
        "--simulate-integration",
        action="store_true",
        help="With --plan, simulate main update + main→beta sync + beta finalize locally",
    )
    parser.add_argument(
        "--simulation-work-dir",
        default="/tmp/sf-game-version-sim",
        help="Directory for temporary integration simulation clones",
    )
    parser.add_argument(
        "--integrate-main-into-beta",
        metavar="MAIN_SHA",
        help="Merge MAIN_SHA into the current checkout and finalize beta metadata",
    )
    parser.add_argument(
        "--beta-target-version",
        help="Beta TOC version used with --integrate-main-into-beta",
    )
    parser.add_argument(
        "--game-version",
        help="Human-readable game version for compatibility changelog entries",
    )
    parser.add_argument(
        "--beta-update-needed",
        action="store_true",
        help="With --integrate-main-into-beta, also treat this as a beta release bump",
    )
    parser.add_argument(
        "--no-commit",
        action="store_true",
        help="With --integrate-main-into-beta, prepare the tree without creating a commit",
    )
    args = parser.parse_args()

    if args.assert_no_conflicts:
        assert_no_conflicting_workflow_runs(
            os.environ.get("GITHUB_REPOSITORY"),
            os.environ.get("GITHUB_TOKEN"),
            current_run_id=args.current_run_id,
        )
        print("[sync] No conflicting release workflow runs detected")
        return 0

    if args.materialize_helpers:
        if not args.workflow_sha:
            parser.error("--materialize-helpers requires --workflow-sha")
        paths = materialize_workflow_helpers(
            Path(args.repo_path or "."),
            args.workflow_sha,
            args.materialize_helpers,
        )
        print(f"[sync] Materialized {len(paths)} helpers into {args.materialize_helpers}")
        for path in paths:
            print(f"[sync]   {path}")
        return 0

    if args.ensure_beta_release_concurrency:
        path = Path(args.ensure_beta_release_concurrency)
        changed = ensure_release_channels_concurrency(path)
        if changed:
            print(f"[sync] Updated concurrency group in {path} to release-channels")
        else:
            print(f"[sync] No beta-release concurrency group rewrite needed in {path}")
        return 0

    if args.integrate_main_into_beta:
        if not args.apply_interface or not args.beta_target_version or not args.game_version:
            parser.error(
                "--integrate-main-into-beta requires --apply-interface, "
                "--beta-target-version, and --game-version"
            )
        result = integrate_main_into_beta(
            Path(args.repo_path or "."),
            main_sha=args.integrate_main_into_beta,
            beta_interface=str(_validate_interface(args.apply_interface)),
            beta_version=parse_version(args.beta_target_version).raw,
            game_version=args.game_version,
            beta_update_needed=bool(args.beta_update_needed),
            commit=not args.no_commit,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        if result.get("commit_sha"):
            write_output("pushed_sha", result["commit_sha"])
            write_output("completed", "true")
            write_output("synced", "true" if result.get("synced") else "false")
        return 0

    if args.verify_sha:
        if not args.verify_ref:
            parser.error("--verify-sha requires --verify-ref")
        verify_git_sha(Path(args.repo_path or "."), args.verify_ref, args.verify_sha, label=args.verify_ref)
        print(f"[sync] Verified {args.verify_ref} == {args.verify_sha}")
        return 0

    if args.apply_toc_version or args.apply_interface or args.update_readme:
        if not args.apply_toc_version or not args.apply_interface:
            parser.error("--apply-toc-version and --apply-interface are required together")
        interface = str(_validate_interface(args.apply_interface))
        version = parse_version(args.apply_toc_version).raw
        toc_path = Path(args.toc_path)
        changed = update_packaged_tocs(toc_path, interface, version)
        print(f"[sync] Packaged TOC update changed_files={changed} interface={interface} version={version}")
        if args.update_readme:
            readme_changed = update_readme_badges("README.md", version, interface, args.update_readme)
            print(f"[sync] README badge update changed={readme_changed} track={args.update_readme}")
        return 0

    if args.plan or args.requested_version:
        if not args.requested_version:
            parser.error("--plan requires --requested-version")
        return run_plan_mode(args)

    game_version, target_interface_int, resolver_strategy = resolve_live_interface(
        args.region,
        allow_network=not args.no_network,
    )
    target_interface = str(target_interface_int)
    print(f"[sync] Resolver strategy: {resolver_strategy}")
    if game_version:
        print(f"[sync] Live game version: {game_version}")
    else:
        print("[sync] Live game version: unknown (resolved without game version source)")
    print(f"[sync] Target Interface: {target_interface}")
    write_output("resolver_strategy", resolver_strategy)
    write_output("game_version", game_version or "")

    if args.dry_run and (not args.main_path or not args.beta_path):
        print("[sync][dry-run] Resolver check complete; no repository updates performed")
        return 0

    if not args.main_path or not args.beta_path:
        parser.error("--main-path and --beta-path are required when not using --dry-run resolver-only mode")

    main_toc = Path(args.main_path) / args.toc_path
    beta_toc = Path(args.beta_path) / args.toc_path

    main_interface, main_version_raw = read_toc_fields(main_toc)
    beta_interface, beta_version_raw = read_toc_fields(beta_toc)

    main_version = parse_version(main_version_raw)
    beta_version = parse_version(beta_version_raw)

    if main_version.kind != beta_version.kind:
        raise RuntimeError("Main and beta use different version formats; cannot update safely")

    write_output("interface", target_interface)

    main_update_needed = main_interface != target_interface
    beta_update_needed = beta_interface != target_interface

    if not (main_update_needed or beta_update_needed):
        print("[sync] Interface already up to date on both branches; exiting")
        write_output("main_updated", "false")
        write_output("beta_updated", "false")
        write_output("beta_build", "false")
        write_output("main_version", main_version_raw)
        write_output("beta_version", beta_version_raw)
        return 0

    new_main_version, new_beta_version, beta_ahead = compute_updated_versions(
        main_version,
        beta_version,
        main_update_needed,
        beta_update_needed=beta_update_needed,
    )

    if args.dry_run:
        print(f"[sync][dry-run] Main: {main_version.raw} -> {new_main_version.raw}")
        print(f"[sync][dry-run] Beta: {beta_version.raw} -> {new_beta_version.raw}")
        print(f"[sync][dry-run] Main TOC change needed: {main_update_needed}")
        print(f"[sync][dry-run] Beta TOC change needed: {beta_update_needed}")
        print(f"[sync][dry-run] Beta ahead of main: {beta_ahead}")
        write_output("main_updated", "true" if main_update_needed else "false")
        write_output("beta_updated", "true" if beta_update_needed else "false")
        write_output("beta_build", "true" if beta_ahead else "false")
        write_output("main_version", new_main_version.raw if main_update_needed else main_version.raw)
        write_output("beta_version", new_beta_version.raw if beta_update_needed else beta_version.raw)
        print("[sync][dry-run] No changes were committed")
        return 0

    print(f"[sync] Main: {main_version.raw} -> {new_main_version.raw}")
    print(f"[sync] Beta: {beta_version.raw} -> {new_beta_version.raw}")

    main_changed = (
        update_packaged_tocs(main_toc, target_interface, new_main_version.raw) if main_update_needed else False
    )
    beta_changed = (
        update_packaged_tocs(beta_toc, target_interface, new_beta_version.raw) if beta_update_needed else False
    )

    if args.commit_and_push:
        git_config(args.main_path)
        git_config(args.beta_path)
        if main_changed:
            message = f"chore: bump Interface to {target_interface} and version to {new_main_version.raw}"
            git_commit_and_push(args.main_path, args.main_branch, main_toc, message)
        if beta_changed:
            message = f"chore: bump Interface to {target_interface} and version to {new_beta_version.raw}"
            git_commit_and_push(args.beta_path, args.beta_branch, beta_toc, message)
    else:
        print("[sync] Commit/push disabled (default). Workflow should handle branch mutations.")

    write_output("main_updated", "true" if main_changed else "false")
    write_output("beta_updated", "true" if beta_changed else "false")
    write_output("main_version", new_main_version.raw if main_update_needed else main_version.raw)
    write_output("beta_version", new_beta_version.raw if beta_update_needed else beta_version.raw)
    write_output("beta_build", "true" if beta_ahead else "false")

    print(f"[sync] Beta ahead of main: {beta_ahead}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"::error::{exc}")
        sys.exit(1)
