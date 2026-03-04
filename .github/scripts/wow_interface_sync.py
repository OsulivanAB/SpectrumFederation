#!/usr/bin/env python3
"""
Synchronize WoW Interface and addon versions on main and beta branches.

Fetches the latest live game Interface value from Blizzard using client
credentials, bumps main, preserves beta's lead over main, commits, and pushes.
Designed to be called from CI with two checked-out worktrees (main and beta).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from base64 import b64encode
from pathlib import Path
from urllib import error, parse, request


PATCH_ENDPOINTS = {
    "live": "https://us.patch.battle.net:1119/wow/versions",
}

RETRYABLE_HTTP_STATUS_CODES = {429, 500, 502, 503, 504}
MAX_BACKOFF_SECONDS = 8


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


def urlopen_with_retry(req, timeout=15, max_attempts=3):
    """Open a URL with bounded retries for transient Blizzard API failures.

    Args:
        req: urllib request object or URL string accepted by urllib.request.urlopen.
        timeout: Request timeout in seconds.
        max_attempts: Total number of attempts before raising the last error.

    Returns:
        The HTTP response object from urllib.request.urlopen.

    Retry behavior:
        Uses exponential backoff (1s, 2s, 4s...) capped by MAX_BACKOFF_SECONDS.
        Retries HTTP status codes 429, 500, 502, 503, and 504.

    Raises:
        urllib.error.HTTPError: For non-retryable status codes or after retries are exhausted.
        urllib.error.URLError: For network failures after retries are exhausted.
        TimeoutError: For timeout failures after retries are exhausted.
    """
    for attempt in range(1, max_attempts + 1):
        try:
            return request.urlopen(req, timeout=timeout)
        except error.HTTPError as exc:
            retryable = exc.code in RETRYABLE_HTTP_STATUS_CODES
            if not retryable or attempt == max_attempts:
                raise
            print(
                f"[sync] HTTP {exc.code} from Blizzard API (attempt {attempt}/{max_attempts}); retrying...",
                file=sys.stderr,
            )
        except (error.URLError, TimeoutError):
            if attempt == max_attempts:
                raise
            print(
                f"[sync] Network error from Blizzard API (attempt {attempt}/{max_attempts}); retrying...",
                file=sys.stderr,
            )

        if attempt < max_attempts:
            backoff_seconds = min(2 ** (attempt - 1), MAX_BACKOFF_SECONDS)
            time.sleep(backoff_seconds)


def fetch_access_token(client_id, client_secret, region="us"):
    url = "https://oauth.battle.net/token"
    data = parse.urlencode({"grant_type": "client_credentials"}).encode("utf-8")
    auth_header = b64encode(f"{client_id}:{client_secret}".encode("utf-8")).decode("utf-8")

    req = request.Request(url, data=data, headers={"Authorization": f"Basic {auth_header}"})

    try:
        with urlopen_with_retry(req, timeout=15) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
            token = payload.get("access_token")
            if not token:
                raise RuntimeError("access_token missing in Blizzard OAuth response")
            return token
    except error.HTTPError as exc:
        raise RuntimeError(f"HTTP {exc.code} from Blizzard OAuth endpoint") from exc
    except error.URLError as exc:
        raise RuntimeError(f"Failed to reach Blizzard OAuth endpoint: {exc.reason}") from exc


def parse_version_response(response_text):
    lines = response_text.strip().splitlines()
    for line in lines:
        if line.startswith("us|"):
            parts = line.split("|")
            if len(parts) >= 6:
                candidate = parts[5]
                if re.match(r"^\d+\.\d+\.\d+\.\d+$", candidate):
                    return candidate
    raise RuntimeError("Could not parse game version from Blizzard response")


def version_to_interface(version):
    parts = version.split(".")
    if len(parts) < 3:
        raise RuntimeError(f"Unexpected game version format: {version}")

    major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
    return f"{major}{minor:02d}{patch:02d}"


def fetch_live_interface(client_id, client_secret):
    token = fetch_access_token(client_id, client_secret)
    url = PATCH_ENDPOINTS["live"]

    req = request.Request(url, headers={"Authorization": f"Bearer {token}"})

    try:
        with urlopen_with_retry(req, timeout=15) as resp:
            payload = resp.read().decode("utf-8")
    except error.HTTPError as exc:  # pragma: no cover - network errors are runtime concerns
        raise RuntimeError(f"HTTP {exc.code} from Blizzard version endpoint") from exc
    except error.URLError as exc:  # pragma: no cover
        raise RuntimeError(f"Failed to reach Blizzard version endpoint: {exc.reason}") from exc

    game_version = parse_version_response(payload)
    interface = version_to_interface(game_version)
    return game_version, interface


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

    new_patch = info.patch + 1
    version = f"{info.major}.{info.minor}.{new_patch}"
    return VersionInfo(version, kind="semver", major=info.major, minor=info.minor, patch=new_patch)


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


def update_toc(toc_path, interface, version):
    path = Path(toc_path)
    content = path.read_text(encoding="utf-8")

    new_content = re.sub(r"^## Interface:.*$", f"## Interface: {interface}", content, flags=re.MULTILINE)
    new_content = re.sub(r"^## Version:.*$", f"## Version: {version}", new_content, flags=re.MULTILINE)

    if new_content != content:
        path.write_text(new_content, encoding="utf-8")
        return True
    return False


def git_config(path):
    subprocess.run(["git", "-C", str(path), "config", "user.name", "github-actions[bot]"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "github-actions[bot]@users.noreply.github.com"], check=True)


def git_commit_and_push(path, branch, toc_path, message):
    rel_toc = os.path.relpath(toc_path, path)

    diff_check = subprocess.run(["git", "-C", str(path), "diff", "--quiet", "--", rel_toc])
    if diff_check.returncode == 0:
        return False

    subprocess.run(["git", "-C", str(path), "add", rel_toc], check=True)
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


def main():
    parser = argparse.ArgumentParser(description="Sync WoW Interface and addon versions across branches")
    parser.add_argument("--toc-path", default="SpectrumFederation/SpectrumFederation.toc", help="Path to TOC file")
    parser.add_argument("--main-path", required=True, help="Path to working tree for main branch")
    parser.add_argument("--beta-path", required=True, help="Path to working tree for beta branch")
    parser.add_argument("--main-branch", default="main", help="Main branch name (default: main)")
    parser.add_argument("--beta-branch", default="beta", help="Beta branch name (default: beta)")
    parser.add_argument("--addon-name", default="SpectrumFederation", help="Addon name for logging")
    args = parser.parse_args()

    client_id = os.environ.get("BLIZZARD_API_ID")
    client_secret = os.environ.get("BLIZZARD_API_SECRET")

    if not client_id or not client_secret:
        print("BLIZZARD_API_ID and BLIZZARD_API_SECRET must be set", file=sys.stderr)
        return 1

    game_version, target_interface = fetch_live_interface(client_id, client_secret)
    print(f"[sync] Live game version: {game_version}")
    print(f"[sync] Target Interface: {target_interface}")

    main_toc = Path(args.main_path) / args.toc_path
    beta_toc = Path(args.beta_path) / args.toc_path

    main_interface, main_version_raw = read_toc_fields(main_toc)
    beta_interface, beta_version_raw = read_toc_fields(beta_toc)

    main_version = parse_version(main_version_raw)
    beta_version = parse_version(beta_version_raw)

    if main_version.kind != beta_version.kind:
        raise RuntimeError("Main and beta use different version formats; cannot preserve offset safely")

    write_output("interface", target_interface)
    write_output("main_version", main_version_raw)
    write_output("beta_version", beta_version_raw)

    main_update_needed = main_interface != target_interface
    beta_update_needed = beta_interface != target_interface

    if not (main_update_needed or beta_update_needed):
        print("[sync] Interface already up to date on both branches; exiting")
        write_output("main_updated", "false")
        write_output("beta_updated", "false")
        write_output("beta_build", "false")
        return 0

    git_config(args.main_path)
    git_config(args.beta_path)

    new_main_version = bump_main_version(main_version) if main_update_needed else main_version
    main_value_new = version_value(new_main_version)
    offset = version_value(beta_version) - version_value(main_version)
    beta_value_new = main_value_new + offset
    new_beta_version = decode_value(beta_value_new, beta_version)

    print(f"[sync] Main: {main_version.raw} -> {new_main_version.raw}")
    print(f"[sync] Beta: {beta_version.raw} -> {new_beta_version.raw} (offset preserved)")

    main_changed = update_toc(main_toc, target_interface, new_main_version.raw)
    beta_changed = update_toc(beta_toc, target_interface, new_beta_version.raw)

    main_committed = False
    beta_committed = False

    if main_changed:
        message = f"chore: bump Interface to {target_interface} and version to {new_main_version.raw}"
        main_committed = git_commit_and_push(args.main_path, args.main_branch, main_toc, message)

    if beta_changed:
        message = f"chore: bump Interface to {target_interface} and version to {new_beta_version.raw}"
        beta_committed = git_commit_and_push(args.beta_path, args.beta_branch, beta_toc, message)

    write_output("main_updated", "true" if main_committed else "false")
    write_output("beta_updated", "true" if beta_committed else "false")
    write_output("main_version", new_main_version.raw)
    write_output("beta_version", new_beta_version.raw)

    # Determine whether beta is ahead after the sync
    beta_ahead = version_value(new_beta_version) > version_value(new_main_version)
    write_output("beta_build", "true" if beta_ahead else "false")

    print(f"[sync] Beta build required: {beta_ahead}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
