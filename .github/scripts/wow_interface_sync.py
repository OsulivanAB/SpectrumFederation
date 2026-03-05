#!/usr/bin/env python3
"""
Synchronize WoW Interface and addon versions on main and beta branches.

Fetches the latest live game Interface value from Blizzard using client
credentials, bumps main, preserves beta's lead over main, commits, and pushes.
Designed to be called from CI with two checked-out worktrees (main and beta).
"""

import argparse
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib import error, request


PATCH_VERSIONS_URL_TEMPLATE = "https://{region}.patch.battle.net:1119/wow/versions"
WOWHEAD_LIVE_URL = "https://www.wowhead.com/"
INTERFACE_MIN = 100000
INTERFACE_MAX = 999999
USER_AGENT = "SpectrumFederation-WoWInterfaceSync/1.0 (+https://github.com/OsulivanAB/SpectrumFederation)"


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

    if isinstance(last_error, error.HTTPError):
        raise RuntimeError(f"HTTP {last_error.code} from {url}") from last_error

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


def version_to_interface(version):
    parts = version.split(".")
    if len(parts) < 3:
        raise RuntimeError(f"Unexpected game version format: {version}")

    major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
    return int(f"{major}{minor:02d}{patch:02d}")


def parse_wowhead_interface_response(html):
    patterns = [
        r"(?is)\b(?:live|retail)?\s*interface\b[^0-9]{0,40}(?P<iface>\d{6})\b",
        r'(?is)"interface"\s*:\s*"?(?P<iface>\d{6})"?',
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, html):
            interface_int = int(match.group("iface"))
            if _is_plausible_interface(interface_int):
                return interface_int
    raise RuntimeError("Could not parse interface from Wowhead HTML")


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


def _resolve_wowhead():
    payload = http_get_with_retries(
        WOWHEAD_LIVE_URL,
        timeout=30,
        attempts=3,
        base_sleep=1,
        max_sleep=20,
    )
    return None, _validate_interface(parse_wowhead_interface_response(payload))


def resolve_live_interface(region):
    override = os.environ.get("LIVE_INTERFACE_OVERRIDE")
    if override:
        return None, _validate_interface(override)

    failures = []

    try:
        game_version, interface_int = _resolve_patch_server(region)
        print(f"[resolver] Strategy A (patch server) succeeded for region '{region}'")
        return game_version, interface_int
    except Exception as exc:
        failures.append(f"Strategy A (patch server): {exc}")
        print(f"[resolver] Strategy A (patch server) failed: {exc}")

    try:
        game_version, interface_int = _resolve_wowhead()
        print("[resolver] Strategy B (Wowhead scrape) succeeded")
        return game_version, interface_int
    except Exception as exc:
        failures.append(f"Strategy B (Wowhead scrape): {exc}")
        print(f"[resolver] Strategy B (Wowhead scrape) failed: {exc}")

    failure_text = "; ".join(failures)
    raise RuntimeError(f"Unable to resolve live interface. {failure_text}")


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
    parser.add_argument("--main-path", help="Path to working tree for main branch")
    parser.add_argument("--beta-path", help="Path to working tree for beta branch")
    parser.add_argument("--main-branch", default="main", help="Main branch name (default: main)")
    parser.add_argument("--beta-branch", default="beta", help="Beta branch name (default: beta)")
    parser.add_argument("--addon-name", default="SpectrumFederation", help="Addon name for logging")
    parser.add_argument("--region", default="us", help="Patch region to query (default: us)")
    parser.add_argument("--dry-run", action="store_true", help="Resolve interface and print actions without committing")
    args = parser.parse_args()

    game_version, target_interface_int = resolve_live_interface(args.region)
    target_interface = str(target_interface_int)
    if game_version:
        print(f"[sync] Live game version: {game_version}")
    else:
        print("[sync] Live game version: unknown (resolved without game version source)")
    print(f"[sync] Target Interface: {target_interface}")

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

    if args.dry_run:
        new_main_version = bump_main_version(main_version) if main_update_needed else main_version
        main_value_new = version_value(new_main_version)
        offset = version_value(beta_version) - version_value(main_version)
        beta_value_new = main_value_new + offset
        new_beta_version = decode_value(beta_value_new, beta_version)
        print(f"[sync][dry-run] Main: {main_version.raw} -> {new_main_version.raw}")
        print(f"[sync][dry-run] Beta: {beta_version.raw} -> {new_beta_version.raw} (offset preserved)")
        print("[sync][dry-run] No changes were committed")
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
