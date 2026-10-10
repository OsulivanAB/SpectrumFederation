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

import validate_packaging

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
    for child_name in validate_packaging.CHILD_ADDON_NAMES:
        child_toc = repo_root / child_name / f"{child_name}.toc"
        if child_toc.exists() and child_toc.resolve() != toc_path.resolve():
            extra.append(child_toc)
    return extra


def packaged_toc_relpaths(toc_path="SpectrumFederation/SpectrumFederation.toc"):
    """Return repo-relative TOC paths for the parent and packaged children."""
    toc_path = Path(toc_path)
    paths = [str(toc_path).replace("\\", "/")]
    parent_name = toc_path.parent.name
    for child_name in validate_packaging.CHILD_ADDON_NAMES:
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


def github_release_exists(version, repo, token):
    """Return True when GitHub already has release tag v{version}."""
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
            return 200 <= getattr(resp, "status", 200) < 300
    except error.HTTPError as exc:
        if exc.code == 404:
            return False
        raise RuntimeError(f"GitHub release lookup failed for {tag}: HTTP {exc.code}") from exc
    except (error.URLError, TimeoutError, ConnectionError) as exc:
        raise RuntimeError(f"GitHub release lookup failed for {tag}: {exc}") from exc


def plan_branch_action(*, interface_matches, version_raw, repo, token):
    """Return update, publish, or none for one branch."""
    if not interface_matches:
        return "update"

    exists = github_release_exists(version_raw, repo, token)
    if exists is False:
        return "publish"
    # Release present or unverifiable: still allow idempotent publish retries for
    # CurseForge/Wago partial failures without bumping the addon version again.
    return "publish"


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
    beta_update_needed = beta_interface != target_interface_str

    new_main_version, new_beta_version, beta_ahead = compute_updated_versions(
        main_version,
        beta_version,
        main_update_needed,
        beta_update_needed=beta_update_needed,
    )

    main_target_version = new_main_version.raw if main_update_needed else main_version.raw
    beta_target_version = new_beta_version.raw if beta_update_needed else beta_version.raw

    main_action = plan_branch_action(
        interface_matches=not main_update_needed,
        version_raw=main_target_version,
        repo=repo,
        token=token,
    )
    beta_action = plan_branch_action(
        interface_matches=not beta_update_needed,
        version_raw=beta_target_version,
        repo=repo,
        token=token,
    )

    # When the Interface is already correct and the GitHub release exists, the
    # branch still uses action=publish so a rerun can repair partial CF/Wago
    # uploads without commits. Callers may treat that as an idempotent retry.
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
        "any_work": True,
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


def write_step_summary(plan, *, dry_run=False):
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
    )
    plan["resolver_strategy"] = resolver_strategy

    print(json.dumps(plan, indent=2, sort_keys=True))
    _emit_plan_outputs(plan)
    write_step_summary(plan, dry_run=args.dry_run)
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
    args = parser.parse_args()

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
