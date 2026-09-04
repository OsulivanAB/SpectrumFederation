"""
Package addon and create GitHub and Wago releases.

Creates a zip file with proper structure, publishes to GitHub Releases,
and uploads the same zip to Wago Addons with an explicit stability value.
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib import error as urllib_error
from urllib import request as urllib_request

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import blizzard_api

WAGO_API_BASE = "https://addons.wago.io/api"
WAGO_GAME_DATA_URL = f"{WAGO_API_BASE}/data/game"
WAGO_API_KEY_ENV = "WAGO_API_KEY"
WAGO_LEGACY_WEBHOOK_SECRET_ENV = "WAGO_API_SECRET"
WAGO_USER_AGENT = (
    "SpectrumFederation-PublishRelease/1.0 "
    "(+https://github.com/OsulivanAB/SpectrumFederation)"
)
WAGO_STABILITY_VALUES = ("stable", "beta", "alpha")
WAGO_UPLOAD_TIMEOUT_SECONDS = 60
WAGO_GAME_DATA_TIMEOUT_SECONDS = 15
WAGO_DUPLICATE_PHRASES = (
    "already exists",
    "already been uploaded",
    "already been released",
    "already been published",
    "duplicate version",
    "version already",
    "label already",
    "label has already",
    "release already",
)
PRERELEASE_MARKER_RE = re.compile(
    r"-(alpha|beta|rc)(?=[.\-]|$)",
    re.IGNORECASE,
)
SECRET_LIKE_RE = re.compile(
    r"(authorization:\s*(?:token|bearer|basic)\s+)\S+"
    r"|(bearer\s+)[A-Za-z0-9._\-]+"
    r"|\b(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b"
    r"|(\b(?:WAGO_API_KEY|WAGO_API_SECRET|GH_TOKEN|GITHUB_TOKEN)\s*[:=]\s*)\S+",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class ReleaseClassification:
    """Shared GitHub/Wago release classification derived from the version string."""

    version: str
    is_prerelease: bool
    wago_stability: str
    github_release_kind: str


@dataclass(frozen=True)
class WagoPublishPlan:
    """Non-secret Wago upload plan used by dry-run logging and live publishing."""

    project_id: str
    label: str
    stability: str
    supported_retail_patch: str
    patch_match: str
    changelog: str
    zip_path: Path
    endpoint: str


def classify_release(version):
    """Classify a version for GitHub prerelease flags and Wago stability.

    Matching is case-insensitive and looks for `-alpha`, `-beta`, and `-rc`
    prerelease identifiers. `-rc` maps to Wago `beta`.
    """
    version = version or ""
    match = PRERELEASE_MARKER_RE.search(version)
    if not match:
        return ReleaseClassification(
            version=version,
            is_prerelease=False,
            wago_stability="stable",
            github_release_kind="release",
        )

    marker = match.group(1).lower()
    stability = "alpha" if marker == "alpha" else "beta"
    return ReleaseClassification(
        version=version,
        is_prerelease=True,
        wago_stability=stability,
        github_release_kind="prerelease",
    )


def toc_path_for_addon(addon_name):
    """Return the primary TOC path for an addon folder."""
    return Path(addon_name) / f"{addon_name}.toc"


def read_toc_field(toc_file, field_name):
    """Return a TOC metadata field value or None."""
    toc_file = Path(toc_file)
    if not toc_file.exists():
        return None
    content = toc_file.read_text(encoding="utf-8")
    pattern = re.compile(rf"^## {re.escape(field_name)}:\s*(.+)$", re.MULTILINE)
    match = pattern.search(content)
    if not match:
        return None
    return match.group(1).strip()


def get_wago_project_id(addon_name):
    """Read the public Wago project ID from the parent addon's TOC."""
    toc_file = toc_path_for_addon(addon_name)
    project_id = read_toc_field(toc_file, "X-Wago-ID")
    if not project_id:
        print(f"::error ::Missing ## X-Wago-ID in {toc_file}")
        print("          Add the public Wago project ID to the parent TOC.")
        return None
    if not re.fullmatch(r"[A-Za-z0-9]{8}", project_id):
        print(f"::error ::X-Wago-ID '{project_id}' in {toc_file} is not an 8-character Wago project ID")
        return None
    return project_id


def wago_version_endpoint(project_id):
    """Return the documented Wago version-upload URL for a project."""
    return f"{WAGO_API_BASE}/projects/{project_id}/version"


def interface_to_retail_patch(interface):
    """Convert a 6-digit TOC Interface value to a Wago retail patch string."""
    return blizzard_api.interface_to_display(interface)


def parse_patch_tuple(patch):
    """Parse a dotted patch string into comparable integers."""
    parts = str(patch).split(".")
    if not parts or any(not part.isdigit() for part in parts):
        return None
    return tuple(int(part) for part in parts)


def select_wago_retail_patch(desired_patch, available_patches):
    """Choose a Wago-supported retail patch for the desired game version.

    Prefer an exact catalog match. If Wago has not listed the current Retail
    patch yet, use the highest catalog patch that is still less than or equal
    to the desired version.
    """
    desired = parse_patch_tuple(desired_patch)
    if desired is None:
        raise ValueError(f"Invalid retail patch '{desired_patch}'")

    normalized = [str(patch) for patch in available_patches or [] if str(patch).strip()]
    if desired_patch in normalized:
        return desired_patch, "exact"

    candidates = []
    for patch in normalized:
        parsed = parse_patch_tuple(patch)
        if parsed is not None and parsed <= desired:
            candidates.append((parsed, patch))

    if not candidates:
        raise ValueError(
            f"Wago game catalog has no retail patch at or below '{desired_patch}'"
        )

    candidates.sort()
    return candidates[-1][1], "fallback"


def fetch_wago_game_data(timeout=WAGO_GAME_DATA_TIMEOUT_SECONDS):
    """Fetch Wago's public game-version catalog. Returns None on failure."""
    request = urllib_request.Request(
        WAGO_GAME_DATA_URL,
        headers={
            "Accept": "application/json",
            "User-Agent": WAGO_USER_AGENT,
        },
        method="GET",
    )
    try:
        with urllib_request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib_error.URLError, TimeoutError, json.JSONDecodeError, OSError, UnicodeError) as error:
        print(f"[publish-release] Warning: Failed to fetch Wago game catalog: {error}")
        return None

    if not isinstance(payload, dict):
        print("[publish-release] Warning: Wago game catalog was not a JSON object")
        return None
    return payload


def resolve_supported_retail_patch(interface, game_data=None):
    """Return (patch, match_kind) for Wago's supported_retail_patch field."""
    desired_patch = interface_to_retail_patch(interface)
    if not game_data:
        return desired_patch, "unvalidated"

    available = (game_data.get("patches") or {}).get("retail") or []
    patch, match_kind = select_wago_retail_patch(desired_patch, available)
    return patch, match_kind


def build_wago_metadata(label, stability, changelog, supported_retail_patch):
    """Build the JSON object Wago expects in the multipart `metadata` field."""
    if stability not in WAGO_STABILITY_VALUES:
        raise ValueError(f"Invalid Wago stability '{stability}'")
    return {
        "label": label,
        "stability": stability,
        "changelog": changelog or "",
        "supported_retail_patch": supported_retail_patch,
    }


def encode_multipart_form(fields, files):
    """Encode multipart/form-data without placing credentials in the body."""
    boundary = f"----SpectrumFederationFormBoundary{uuid.uuid4().hex}"
    chunks = []

    for name, value in fields.items():
        chunks.append(f"--{boundary}".encode())
        chunks.append(f'Content-Disposition: form-data; name="{name}"'.encode())
        chunks.append(b"")
        chunks.append(value.encode() if isinstance(value, str) else value)

    for name, path in files.items():
        file_path = Path(path)
        filename = file_path.name.replace('"', "")
        chunks.append(f"--{boundary}".encode())
        chunks.append(
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"'.encode()
        )
        chunks.append(b"Content-Type: application/zip")
        chunks.append(b"")
        chunks.append(file_path.read_bytes())

    chunks.append(f"--{boundary}--".encode())
    chunks.append(b"")
    return b"\r\n".join(chunks), f"multipart/form-data; boundary={boundary}"


def sanitize_output(text):
    """Redact credentials and token-like values from logged output."""
    if not text:
        return text

    def _redact(match):
        prefix = match.group(1) or match.group(2) or match.group(4) or ""
        if prefix:
            return f"{prefix}***"
        return "***"

    return SECRET_LIKE_RE.sub(_redact, str(text))


def format_command(cmd):
    """Format a subprocess command for logging."""
    return shlex.join(str(part) for part in cmd)


def log_command_failure(prefix, error):
    """Log a subprocess failure with masked stdout/stderr."""
    print(f"::error ::{prefix} (exit code {error.returncode})")

    if error.cmd:
        print(f"[publish-release] Command: {format_command(error.cmd)}")

    if error.stdout:
        print("[publish-release] stdout:")
        print(sanitize_output(error.stdout.strip()))

    if error.stderr:
        print("[publish-release] stderr:", file=sys.stderr)
        print(sanitize_output(error.stderr.strip()), file=sys.stderr)


def read_http_error_body(error):
    """Read an HTTPError body without logging request headers."""
    try:
        raw = error.read()
    except (OSError, AttributeError):
        return ""
    if not raw:
        return ""
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="replace")
    return str(raw)


def summarize_wago_http_error(status, body):
    """Return a credential-free summary of a Wago HTTP response."""
    text = sanitize_output((body or "").strip())
    if not text:
        return f"HTTP {status}"

    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        compact = re.sub(r"\s+", " ", text)
        return f"HTTP {status}: {compact[:300]}"

    if isinstance(payload, dict):
        message = (
            payload.get("message")
            or payload.get("error")
            or payload.get("detail")
            or payload.get("title")
        )
        if message:
            return f"HTTP {status}: {sanitize_output(str(message))[:300]}"
    compact = re.sub(r"\s+", " ", text)
    return f"HTTP {status}: {compact[:300]}"


def is_existing_wago_release(status, body):
    """Return True only when the response clearly means this version exists."""
    text = (body or "").lower()
    if status == 409:
        if not text:
            return True
        return any(
            phrase in text
            for phrase in (*WAGO_DUPLICATE_PHRASES, "conflict", "duplicate")
        )
    if status in (400, 422):
        return any(phrase in text for phrase in WAGO_DUPLICATE_PHRASES)
    return False


def get_changelog_for_version(version):
    """Extract changelog content for a specific version from CHANGELOG.md.
    
    Args:
        version: Version string (e.g., '0.0.18' or '0.0.18-beta.1')
        
    Returns:
        String containing the changelog section for this version, or None if not found.
    """
    changelog_path = Path("CHANGELOG.md")
    
    if not changelog_path.exists():
        print("[publish-release] Warning: CHANGELOG.md not found")
        return None
    
    try:
        with open(changelog_path, "r") as f:
            content = f.read()
        
        # For beta versions, try both the exact version and the [Unreleased - Beta] section
        if "-beta" in version:
            # First try to find exact version match
            pattern = rf"^## \[{re.escape(version)}\].*?$"
            match = re.search(pattern, content, re.MULTILINE)
            
            if not match:
                # Fall back to [Unreleased - Beta] section
                pattern = r"^## \[Unreleased - Beta\].*?$"
                match = re.search(pattern, content, re.MULTILINE)
        else:
            # For stable releases, look for exact version
            pattern = rf"^## \[{re.escape(version)}\].*?$"
            match = re.search(pattern, content, re.MULTILINE)
        
        if not match:
            print(f"[publish-release] Warning: No changelog entry found for version {version}")
            return None
        
        # Find the start of this section
        start_pos = match.start()
        
        # Find the next version header (or end of file)
        next_section = re.search(r"^## \[", content[start_pos + len(match.group(0)):], re.MULTILINE)
        
        if next_section:
            end_pos = start_pos + len(match.group(0)) + next_section.start()
        else:
            end_pos = len(content)
        
        # Extract the section (including the header)
        changelog_section = content[start_pos:end_pos].strip()
        
        print(f"[publish-release] ✓ Extracted changelog for version {version}")
        return changelog_section
        
    except (OSError, UnicodeError) as e:
        print(f"[publish-release] Warning: Failed to read changelog: {e}")
        return None


def create_release_json(version, interface, addon_name, zip_filename):
    """Create release.json for WowUp Hub compatibility.
    
    Args:
        version: Version string (e.g., '0.0.19')
        interface: WoW interface version (e.g., 110207)
        addon_name: Name of the addon (e.g., 'SpectrumFederation')
        zip_filename: Name of the zip file (e.g., 'SpectrumFederation-0.0.19.zip')
        
    Returns:
        Path to the generated release.json file
    """
    build_dir = Path("build")
    build_dir.mkdir(exist_ok=True)
    
    json_path = build_dir / "release.json"
    
    release_data = {
        "releases": [
            {
                "filename": zip_filename,
                "nolib": False,
                "metadata": [
                    {
                        "flavor": "mainline",
                        "interface": int(interface)
                    }
                ]
            }
        ]
    }
    
    with open(json_path, 'w') as f:
        json.dump(release_data, f, indent=2)
    
    print(f"[publish-release] ✓ Created {json_path}")
    return json_path


def create_addon_zip(addon_name, version):
    """Create addon zip file with proper structure."""
    build_dir = Path("build")
    build_dir.mkdir(exist_ok=True)
    
    zip_name = f"{addon_name}-{version}.zip"
    zip_path = build_dir / zip_name
    
    # Remove old zip if exists
    if zip_path.exists():
        zip_path.unlink()
    
    print(f"[publish-release] Creating release zip: {zip_path}")

    child_addon_name = "SpectrumFederation_CursedSurgeTracker"
    zip_entries = [addon_name]
    if Path(child_addon_name).exists() and child_addon_name != addon_name:
        zip_entries.append(child_addon_name)
    
    # Create zip using subprocess for consistency with validation
    try:
        subprocess.run(
            ["zip", "-r", str(zip_path), *zip_entries, "-x", "*.git*", "*/AGENTS.md"],
            check=True,
            capture_output=True
        )
        print(f"[publish-release] ✓ Created {zip_path}")
        print(f"[publish-release] Packaged folders: {', '.join(zip_entries)}")
        return zip_path
        
    except subprocess.CalledProcessError as e:
        print(f"::error ::Failed to create release zip: {e}")
        return None


def build_release_notes(version, repo, classification=None):
    """Build release notes for a version."""
    classification = classification or classify_release(version)
    changelog = get_changelog_for_version(version)

    if classification.wago_stability == "stable":
        notes = f"Stable release {version}\n\n"
        branch = "main"
    elif classification.wago_stability == "alpha":
        notes = f"Alpha release {version}\n\n"
        branch = "beta"
    else:
        notes = f"Beta release {version}\n\n"
        branch = "beta"

    if changelog:
        notes += changelog + "\n\n"

    notes += f"[View Full Changelog](https://github.com/{repo}/blob/{branch}/CHANGELOG.md)"
    return notes


def write_release_notes(notes):
    """Write release notes to a file for gh --notes-file."""
    build_dir = Path("build")
    build_dir.mkdir(exist_ok=True)

    notes_path = build_dir / "release-notes.md"
    notes_path.write_text(notes, encoding="utf-8")
    print(f"[publish-release] ✓ Wrote release notes to {notes_path}")
    return notes_path


def release_exists(tag_name, env):
    """Return True when the GitHub release already exists."""
    try:
        subprocess.run(
            ["gh", "release", "view", tag_name],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
        return True
    except subprocess.CalledProcessError as error:
        stderr = (error.stderr or "").lower()
        stdout = (error.stdout or "").lower()
        combined_output = f"{stdout}\n{stderr}"
        if "release not found" in combined_output or "404" in combined_output:
            return False

        log_command_failure(
            f"Failed to check whether GitHub release {tag_name} exists",
            error,
        )
        raise


def update_github_release(tag_name, release_name, notes_path, zip_path, json_path, is_prerelease, env):
    """Update an existing GitHub release and replace assets."""
    print(f"[publish-release] Release {tag_name} already exists; updating it instead")

    edit_cmd = [
        "gh", "release", "edit",
        tag_name,
        "--title", release_name,
        "--notes-file", str(notes_path),
    ]

    if is_prerelease:
        edit_cmd.append("--prerelease")

    upload_cmd = [
        "gh", "release", "upload",
        tag_name,
        str(zip_path),
        str(json_path),
        "--clobber",
    ]

    try:
        subprocess.run(
            edit_cmd,
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
        subprocess.run(
            upload_cmd,
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
        print("[publish-release] ✓ GitHub release updated successfully")
        return "updated"
    except subprocess.CalledProcessError as error:
        log_command_failure("Failed to update GitHub release", error)
        return None


def create_github_release(version, zip_path, json_path, repo, classification, notes_path, dry_run=False):
    """Create GitHub release and upload assets using gh CLI."""
    tag_name = f"v{version}"
    release_name = f"Release {version}"
    is_prerelease = classification.is_prerelease

    if dry_run:
        print("[publish-release] DRY RUN - Would create GitHub release:")
        print(f"  Tag: {tag_name}")
        print(f"  Name: {release_name}")
        print(f"  GitHub classification: {classification.github_release_kind}")
        print(f"  Prerelease: {is_prerelease}")
        print(f"  Assets: {zip_path}, {json_path}")
        print(f"  Notes file: {notes_path}")
        return "dry-run"

    # Support both workflow GH_TOKEN usage and local/manual GITHUB_TOKEN usage.
    github_token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not github_token:
        print("Error: GH_TOKEN or GITHUB_TOKEN environment variable not set")
        return None

    gh_env = {**os.environ, "GH_TOKEN": github_token}

    print(f"[publish-release] Creating GitHub release: {tag_name}")

    cmd = [
        "gh", "release", "create",
        tag_name,
        str(zip_path),
        str(json_path),
        "--title", release_name,
        "--notes-file", str(notes_path),
    ]

    if is_prerelease:
        cmd.append("--prerelease")

    try:
        if release_exists(tag_name, gh_env):
            return update_github_release(
                tag_name,
                release_name,
                notes_path,
                zip_path,
                json_path,
                is_prerelease,
                gh_env,
            )

        result = subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            text=True,
            env=gh_env
        )

        print("[publish-release] ✓ GitHub release created successfully")
        if result.stdout:
            print(sanitize_output(result.stdout))

        return "created"
    except subprocess.CalledProcessError as error:
        log_command_failure("Failed to create GitHub release", error)
        return None
    except FileNotFoundError as error:
        print(f"::error ::Failed to invoke GitHub CLI: {error}")
        return None


def get_wago_api_key(*, required):
    """Return the Wago developer API key, never the legacy webhook secret."""
    raw_key = os.environ.get(WAGO_API_KEY_ENV)
    key = raw_key.strip() if raw_key else ""
    if key:
        return key
    if required:
        print(
            f"::error ::{WAGO_API_KEY_ENV} is not set. "
            "Direct Wago publishing requires the Wago developer API key."
        )
        print(
            f"[publish-release] {WAGO_LEGACY_WEBHOOK_SECRET_ENV} is the legacy "
            "GitHub webhook signing secret and must not be used for the Wago API."
        )
    return None


def build_wago_publish_plan(
    *,
    version,
    classification,
    addon_name,
    interface,
    zip_path,
    changelog,
    game_data=None,
):
    """Build a Wago upload plan from local release metadata."""
    project_id = get_wago_project_id(addon_name)
    if not project_id:
        return None

    try:
        supported_patch, patch_match = resolve_supported_retail_patch(interface, game_data)
    except ValueError as error:
        print(f"::error ::{error}")
        return None

    return WagoPublishPlan(
        project_id=project_id,
        label=version,
        stability=classification.wago_stability,
        supported_retail_patch=supported_patch,
        patch_match=patch_match,
        changelog=changelog,
        zip_path=Path(zip_path),
        endpoint=wago_version_endpoint(project_id),
    )


def log_wago_plan(plan, *, dry_run=False):
    """Log non-secret Wago publish state."""
    prefix = "[publish-release] DRY RUN - Would upload to Wago:" if dry_run else "[publish-release] Wago upload:"
    print(prefix)
    print(f"  Endpoint: POST {plan.endpoint}")
    print(f"  Project ID: {plan.project_id}")
    print(f"  Label: {plan.label}")
    print(f"  Stability: {plan.stability}")
    print(f"  Supported retail patch: {plan.supported_retail_patch} ({plan.patch_match})")
    print(f"  Artifact: {plan.zip_path.name}")
    print("  Authorization: Bearer <redacted>" if not dry_run else "  Authorization: not sent (dry-run)")


def publish_to_wago(plan, *, dry_run=False, opener=None):
    """Upload the addon zip to Wago using the documented multipart API."""
    if dry_run:
        log_wago_plan(plan, dry_run=True)
        return "dry-run"

    api_key = get_wago_api_key(required=True)
    if not api_key:
        return None

    if not plan.zip_path.exists():
        print(f"::error ::Wago artifact does not exist: {plan.zip_path}")
        return None

    metadata = build_wago_metadata(
        plan.label,
        plan.stability,
        plan.changelog,
        plan.supported_retail_patch,
    )
    body, content_type = encode_multipart_form(
        {"metadata": json.dumps(metadata)},
        {"file": plan.zip_path},
    )
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
        "Content-Type": content_type,
        "User-Agent": WAGO_USER_AGENT,
    }
    request = urllib_request.Request(
        plan.endpoint,
        data=body,
        headers=headers,
        method="POST",
    )
    log_wago_plan(plan, dry_run=False)
    urlopen = opener or urllib_request.urlopen

    try:
        with urlopen(request, timeout=WAGO_UPLOAD_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            response_body = response.read().decode("utf-8", errors="replace")
    except urllib_error.HTTPError as error:
        status = error.code
        response_body = read_http_error_body(error)
        summary = summarize_wago_http_error(status, response_body)
        if is_existing_wago_release(status, response_body):
            print(
                "[publish-release] ✓ Wago already has this version; "
                f"treating as success ({summary})"
            )
            return "already-exists"
        if status in (401, 403):
            print(f"::error ::Wago authentication failed ({summary})")
        elif status == 404:
            print(
                f"::error ::Wago project '{plan.project_id}' was not found ({summary})"
            )
        elif status in (400, 422):
            print(f"::error ::Wago rejected the release metadata or file ({summary})")
        elif status >= 500:
            print(f"::error ::Wago server error ({summary})")
        else:
            print(f"::error ::Wago upload failed ({summary})")
        return None
    except (urllib_error.URLError, TimeoutError, OSError) as error:
        print(f"::error ::Wago upload failed: {sanitize_output(str(error))}")
        return None

    if status in (200, 201):
        print(f"[publish-release] ✓ Wago publication succeeded (HTTP {status})")
        return "uploaded"

    summary = summarize_wago_http_error(status, response_body)
    if is_existing_wago_release(status, response_body):
        print(
            "[publish-release] ✓ Wago already has this version; "
            f"treating as success ({summary})"
        )
        return "already-exists"

    print(f"::error ::Wago upload returned unexpected status ({summary})")
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Package addon and create GitHub and Wago releases"
    )
    parser.add_argument(
        "version",
        help="Version to release (e.g., 0.0.15 or 0.0.15-beta.1)"
    )
    parser.add_argument(
        "--interface",
        type=int,
        required=True,
        help="WoW interface version (e.g., 110207 for 11.2.7)"
    )
    parser.add_argument(
        "--addon-name",
        default="SpectrumFederation",
        help="Name of the addon (default: SpectrumFederation)"
    )
    parser.add_argument(
        "--repo",
        default="OsulivanAB/SpectrumFederation",
        help="GitHub repository (default: OsulivanAB/SpectrumFederation)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Don't actually create release, just show what would be done"
    )
    
    args = parser.parse_args()
    classification = classify_release(args.version)
    
    print("[publish-release] Starting release process...")
    print(f"[publish-release] Version: {args.version}")
    print(f"[publish-release] Interface: {args.interface}")
    print(f"[publish-release] GitHub classification: {classification.github_release_kind}")
    print(f"[publish-release] GitHub prerelease: {classification.is_prerelease}")
    print(f"[publish-release] Wago stability: {classification.wago_stability}")
    
    # Construct zip filename
    zip_filename = f"{args.addon_name}-{args.version}.zip"
    
    # Create release.json
    json_path = create_release_json(
        args.version,
        args.interface,
        args.addon_name,
        zip_filename
    )
    
    # Create zip
    zip_path = create_addon_zip(args.addon_name, args.version)
    if not zip_path:
        sys.exit(1)

    notes = build_release_notes(args.version, args.repo, classification)
    notes_path = write_release_notes(notes)

    game_data = fetch_wago_game_data()
    wago_plan = build_wago_publish_plan(
        version=args.version,
        classification=classification,
        addon_name=args.addon_name,
        interface=args.interface,
        zip_path=zip_path,
        changelog=notes,
        game_data=game_data,
    )
    if not wago_plan:
        sys.exit(1)

    print(f"[publish-release] Wago project ID: {wago_plan.project_id}")
    print(
        f"[publish-release] Supported retail patch: {wago_plan.supported_retail_patch} "
        f"({wago_plan.patch_match})"
    )
    print(f"[publish-release] ZIP artifact: {zip_path.name}")

    github_action = create_github_release(
        args.version,
        zip_path,
        json_path,
        args.repo,
        classification,
        notes_path,
        dry_run=args.dry_run
    )
    if not github_action:
        sys.exit(1)
    print(f"[publish-release] GitHub release action: {github_action}")

    wago_action = publish_to_wago(wago_plan, dry_run=args.dry_run)
    if not wago_action:
        if github_action in ("created", "updated"):
            print(
                "[publish-release] GitHub release succeeded, but Wago publication failed. "
                "Rerun this script to retry Wago without deleting the GitHub Release. "
                "Do not roll back CurseForge."
            )
        sys.exit(1)
    print(f"[publish-release] Wago publication action: {wago_action}")
    
    print("[publish-release] ✅ Release published successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
