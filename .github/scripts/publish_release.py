"""
Package addon and create GitHub, CurseForge, and Wago releases.

Creates one canonical zip, publishes it to GitHub Releases first, then
uploads that same zip to CurseForge and Wago independently.
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
import validate_packaging

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
CURSEFORGE_API_BASE = "https://wow.curseforge.com/api"
CURSEFORGE_API_TOKEN_ENV = "CURSEFORGE_API_TOKEN"
CURSEFORGE_USER_AGENT = (
    "SpectrumFederation-PublishRelease/1.0 "
    "(+https://github.com/OsulivanAB/SpectrumFederation)"
)
CURSEFORGE_UPLOAD_TIMEOUT_SECONDS = 60
CURSEFORGE_CATALOG_TIMEOUT_SECONDS = 15
CURSEFORGE_RELEASE_TYPES = ("alpha", "beta", "release")
CURSEFORGE_PROJECT_ID_RE = re.compile(r"^[1-9][0-9]{0,11}$")
CURSEFORGE_CHANGELOG_SOURCE = "CHANGELOG.md"
CURSEFORGE_DUPLICATE_PHRASES = (
    "already exists",
    "already been uploaded",
    "already been published",
    "duplicate file",
    "duplicate version",
    "file already",
    "filename already",
    "file name already",
    "version already",
    "display name already",
    "same file",
)
# Names that are not the Retail release track, even when they contain "retail".
CURSEFORGE_NON_RETAIL_TYPE_MARKERS = ("classic", "ptr", "beta", "arena", "season")
_CURSEFORGE_CATALOG_CACHE = {
    "loaded": False,
    "versions": None,
    "version_types": None,
}
PRERELEASE_MARKER_RE = re.compile(
    r"-(alpha|beta|rc)(?=[.\-]|$)",
    re.IGNORECASE,
)
SECRET_LIKE_RE = re.compile(
    r"(authorization:\s*(?:token|bearer|basic)\s+)\S+"
    r"|(x-api-token:\s*)\S+"
    r"|(bearer\s+)[A-Za-z0-9._\-]+"
    r"|\b(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b"
    r"|(\b(?:WAGO_API_KEY|WAGO_API_SECRET|GH_TOKEN|GITHUB_TOKEN|CURSEFORGE_API_TOKEN)\s*[:=]\s*)\S+",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class ReleaseClassification:
    """Shared GitHub/Wago/CurseForge classification derived from the version string."""

    version: str
    is_prerelease: bool
    wago_stability: str
    github_release_kind: str
    curseforge_release_type: str


@dataclass(frozen=True)
class CurseForgePublishPlan:
    """Non-secret CurseForge upload plan used by dry-run logging and live publishing."""

    project_id: str
    version: str
    release_type: str
    retail_patch: str
    game_version_id: int | None
    game_version_name: str | None
    patch_match: str | None
    changelog: str
    changelog_source: str
    zip_path: Path
    endpoint: str
    action: str


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


def curseforge_release_type_for_stability(wago_stability):
    """Map the shared stability value onto CurseForge's releaseType enum."""
    if wago_stability == "stable":
        return "release"
    if wago_stability in ("alpha", "beta"):
        return wago_stability
    raise ValueError(f"Invalid release stability '{wago_stability}'")


def classify_release(version):
    """Classify a version for GitHub, Wago, and CurseForge.

    Matching is case-insensitive and looks for `-alpha`, `-beta`, and `-rc`
    prerelease identifiers. `-rc` maps to Wago `beta` and CurseForge `beta`.
    Stable versions map to CurseForge `release`.
    """
    version = version or ""
    match = PRERELEASE_MARKER_RE.search(version)
    if not match:
        return ReleaseClassification(
            version=version,
            is_prerelease=False,
            wago_stability="stable",
            github_release_kind="release",
            curseforge_release_type="release",
        )

    marker = match.group(1).lower()
    stability = "alpha" if marker == "alpha" else "beta"
    return ReleaseClassification(
        version=version,
        is_prerelease=True,
        wago_stability=stability,
        github_release_kind="prerelease",
        curseforge_release_type=curseforge_release_type_for_stability(stability),
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
    """Require an exact Wago catalog match for the desired Retail patch.

    Never fall back to an older advertised patch. Publishing a newer Interface
    as an older `supported_retail_patch` would silently claim the wrong
    compatibility window.
    """
    if parse_patch_tuple(desired_patch) is None:
        raise ValueError(f"Invalid retail patch '{desired_patch}'")

    normalized = [str(patch) for patch in available_patches or [] if str(patch).strip()]
    if desired_patch in normalized:
        return desired_patch, "exact"

    raise ValueError(
        f"Wago does not currently advertise Retail patch '{desired_patch}' in "
        f"{WAGO_GAME_DATA_URL}. Live publishing requires an exact catalog match "
        "and will not claim compatibility with an older patch."
    )


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
        raise ValueError(
            f"Could not load Wago's Retail patch catalog from {WAGO_GAME_DATA_URL}. "
            f"Requested patch '{desired_patch}' cannot be verified. "
            "Live publishing requires an exact catalog match."
        )

    available = (game_data.get("patches") or {}).get("retail") or []
    return select_wago_retail_patch(desired_patch, available)


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
        prefix = match.group(1) or match.group(2) or match.group(3) or match.group(5) or ""
        if prefix:
            return f"{prefix}***"
        return "***"

    redacted = SECRET_LIKE_RE.sub(_redact, str(text))
    for env_name in (
        WAGO_API_KEY_ENV,
        WAGO_LEGACY_WEBHOOK_SECRET_ENV,
        CURSEFORGE_API_TOKEN_ENV,
        "GH_TOKEN",
        "GITHUB_TOKEN",
    ):
        secret = os.environ.get(env_name) or ""
        if len(secret) >= 8 and secret in redacted:
            redacted = redacted.replace(secret, "***")
    return redacted


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
    """Return True only when the response clearly says this version exists.

    Wago's public docs do not define HTTP 409 as "already exists". An empty
    or generic conflict body is treated as a hard failure, not a retry success.
    """
    if status not in (400, 409, 422):
        return False
    text = (body or "").lower()
    return any(phrase in text for phrase in WAGO_DUPLICATE_PHRASES)


def _is_beta_prerelease(version):
    """Return True for -beta versions only, not -alpha or -rc."""
    match = PRERELEASE_MARKER_RE.search(version or "")
    return bool(match and match.group(1).lower() == "beta")


def get_changelog_for_version(version):
    """Extract changelog content for a specific version from CHANGELOG.md.

    Beta versions first look for an exact `## [X.Y.Z-beta.N]` heading and then
    fall back to `## [Unreleased - Beta]`, matching the existing changelog
    generator. Stable, alpha, and RC versions use exact-heading lookup only.
    Current automation does not create alpha/RC sections, so those releases
    reuse whatever exact heading already exists and do not invent new ones.
    
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
        
        pattern = rf"^## \[{re.escape(version)}\].*?$"
        match = re.search(pattern, content, re.MULTILINE)

        # Beta-only fallback: changelog automation still writes
        # `[Unreleased - Beta]` for in-progress beta work. Do not reuse that
        # heading for alpha or RC versions.
        if not match and _is_beta_prerelease(version):
            match = re.search(
                r"^## \[Unreleased - Beta\].*?$",
                content,
                re.MULTILINE,
            )
        
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


def packaged_parent_toc_version(addon_name):
    """Return the ## Version value from the packaged parent TOC on disk."""
    toc_file = Path(addon_name) / f"{addon_name}.toc"
    version = validate_packaging.toc_field(toc_file, "Version")
    if not version:
        raise RuntimeError(f"No '## Version:' line in {toc_file}")
    return version


def requested_version_matches_packaged_toc(addon_name, version):
    """Return True when every packaged TOC matches the requested release version."""
    try:
        packaged = packaged_parent_toc_version(addon_name)
    except RuntimeError as exc:
        print(f"::error ::{exc}")
        return False
    if packaged != version:
        print(
            f"::error ::Requested release version {version!r} does not match "
            f"packaged parent TOC {packaged!r}"
        )
        return False
    for name in validate_packaging.packaged_addon_names(addon_name):
        toc_file = Path(name) / f"{name}.toc"
        toc_version = validate_packaging.toc_field(toc_file, "Version")
        if toc_version != version:
            print(
                f"::error ::Packaged TOC version for {name} is {toc_version!r}, "
                f"expected {version!r}"
            )
            return False
    return True


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

    zip_entries = validate_packaging.packaged_addon_names(addon_name)
    cmd = validate_packaging.zip_create_command(zip_path, zip_entries)
    
    # Create zip using subprocess for consistency with validation
    try:
        subprocess.run(cmd, check=True, capture_output=True)
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


def resolve_wago_publish_plan(
    *,
    version,
    classification,
    addon_name,
    interface,
    zip_path,
    changelog,
):
    """Fetch Wago's catalog and build a publish plan. Returns None on failure."""
    game_data = fetch_wago_game_data()
    return build_wago_publish_plan(
        version=version,
        classification=classification,
        addon_name=addon_name,
        interface=interface,
        zip_path=zip_path,
        changelog=changelog,
        game_data=game_data,
    )


def log_wago_summary(plan):
    """Log non-secret Wago plan fields after they have been resolved."""
    print(f"[publish-release] Wago project ID: {plan.project_id}")
    print(
        f"[publish-release] Supported retail patch: {plan.supported_retail_patch} "
        f"({plan.patch_match})"
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
        elif status == 409:
            print(
                f"::error ::Wago returned HTTP 409 without a clear already-exists "
                f"indication ({summary})"
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


def clear_curseforge_catalog_cache():
    """Drop the per-process CurseForge catalog cache."""
    _CURSEFORGE_CATALOG_CACHE["loaded"] = False
    _CURSEFORGE_CATALOG_CACHE["versions"] = None
    _CURSEFORGE_CATALOG_CACHE["version_types"] = None


def get_curseforge_project_id(addon_name):
    """Read the public CurseForge project ID from the parent addon's TOC."""
    toc_file = toc_path_for_addon(addon_name)
    project_id = read_toc_field(toc_file, "X-Curse-Project-ID")
    if not project_id:
        print(f"::error ::Missing ## X-Curse-Project-ID in {toc_file}")
        print("          Add the public CurseForge project ID to the parent TOC.")
        return None
    if not CURSEFORGE_PROJECT_ID_RE.fullmatch(project_id):
        print(
            f"::error ::X-Curse-Project-ID '{project_id}' in {toc_file} "
            "is not a numeric CurseForge project ID"
        )
        return None
    return project_id


def curseforge_upload_endpoint(project_id):
    """Return the documented CurseForge project upload URL."""
    return f"{CURSEFORGE_API_BASE}/projects/{project_id}/upload-file"


def curseforge_auth_headers(token):
    """Build CurseForge author-API headers. The token stays out of the body and URL."""
    return {
        "X-Api-Token": token,
        "Accept": "application/json",
        "User-Agent": CURSEFORGE_USER_AGENT,
    }


def get_curseforge_api_token(*, required):
    """Return the CurseForge Upload API token."""
    raw_token = os.environ.get(CURSEFORGE_API_TOKEN_ENV)
    token = raw_token.strip() if raw_token else ""
    if token:
        return token
    if required:
        print(
            f"::error ::{CURSEFORGE_API_TOKEN_ENV} is not set. "
            "Direct CurseForge publishing requires the CurseForge author API token."
        )
        print(
            "[publish-release] Do not reuse the legacy CurseForge webhook token. "
            f"{CURSEFORGE_API_TOKEN_ENV} is the Upload API credential."
        )
    return None


def curseforge_object_list(payload):
    """Return a list from a bare array or a common object wrapper."""
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("data", "files", "versionTypes", "versions"):
            value = payload.get(key)
            if isinstance(value, list):
                return value
    return None


def fetch_curseforge_json(path, token, *, timeout, opener=None):
    """GET a CurseForge author-API path. Returns (status, body, payload).

    status is None for timeout/network failures. payload is None when the
    body is not JSON. The token is sent only as the X-Api-Token header.
    """
    request = urllib_request.Request(
        f"{CURSEFORGE_API_BASE}/{path.lstrip('/')}",
        headers=curseforge_auth_headers(token),
        method="GET",
    )
    urlopen = opener or urllib_request.urlopen
    try:
        with urlopen(request, timeout=timeout) as response:
            status = getattr(response, "status", 200)
            body = response.read().decode("utf-8", errors="replace")
    except urllib_error.HTTPError as error:
        return error.code, read_http_error_body(error), None
    except (urllib_error.URLError, TimeoutError, OSError) as error:
        return None, sanitize_output(str(error)), None

    try:
        payload = json.loads(body) if body else None
    except json.JSONDecodeError:
        return status, body, None
    return status, body, payload


def load_curseforge_catalog(token, *, opener=None):
    """Load game versions once per process, plus version types when that endpoint exists.

    The documented Game Versions API is required. Version types are used to
    ignore Classic/PTR entries. A missing version-types endpoint does not by
    itself fail the catalog; selection then requires an unambiguous patch name.
    """
    if _CURSEFORGE_CATALOG_CACHE["loaded"]:
        return (
            _CURSEFORGE_CATALOG_CACHE["versions"],
            _CURSEFORGE_CATALOG_CACHE["version_types"],
        )

    status, body, payload = fetch_curseforge_json(
        "game/versions",
        token,
        timeout=CURSEFORGE_CATALOG_TIMEOUT_SECONDS,
        opener=opener,
    )
    versions = curseforge_object_list(payload) if status == 200 else None
    if versions is None:
        summary = (
            sanitize_output(body or "network error")
            if status is None
            else summarize_wago_http_error(status, body)
        )
        if status in (401, 403):
            print(f"::error ::CurseForge authentication failed while loading game versions ({summary})")
        else:
            print(f"::error ::Could not load CurseForge game versions from {CURSEFORGE_API_BASE}/game/versions ({summary})")
        _CURSEFORGE_CATALOG_CACHE["loaded"] = True
        _CURSEFORGE_CATALOG_CACHE["versions"] = None
        _CURSEFORGE_CATALOG_CACHE["version_types"] = None
        return None, None

    type_status, type_body, type_payload = fetch_curseforge_json(
        "game/version-types",
        token,
        timeout=CURSEFORGE_CATALOG_TIMEOUT_SECONDS,
        opener=opener,
    )
    version_types = curseforge_object_list(type_payload) if type_status == 200 else None
    if version_types is None:
        if type_status == 404:
            print(
                "[publish-release] CurseForge version-types endpoint is unavailable. "
                "Retail resolution will require one unambiguous exact patch name."
            )
        else:
            summary = (
                sanitize_output(type_body or "network error")
                if type_status is None
                else summarize_wago_http_error(type_status, type_body)
            )
            print(
                "[publish-release] Warning: Could not load CurseForge version types "
                f"({summary}). Retail resolution will require an unambiguous patch name."
            )

    _CURSEFORGE_CATALOG_CACHE["loaded"] = True
    _CURSEFORGE_CATALOG_CACHE["versions"] = versions
    _CURSEFORGE_CATALOG_CACHE["version_types"] = version_types
    return versions, version_types


def _curseforge_type_id(version):
    return version.get("gameVersionTypeID", version.get("gameVersionTypeId"))


def is_curseforge_retail_version_type(item):
    """Return True for a Retail version type, excluding Classic/PTR/beta tracks."""
    if not isinstance(item, dict):
        return False
    label = f"{item.get('name') or ''} {item.get('slug') or ''}".lower()
    if "retail" not in label:
        return False
    return not any(marker in label for marker in CURSEFORGE_NON_RETAIL_TYPE_MARKERS)


def curseforge_retail_type_ids(version_types):
    """Return Retail gameVersionTypeID values from the version-types catalog."""
    ids = set()
    for item in version_types or []:
        if is_curseforge_retail_version_type(item) and item.get("id") is not None:
            ids.add(item.get("id"))
    return ids


def select_curseforge_retail_game_version(desired_patch, versions, version_types=None):
    """Require the exact Retail CurseForge game version for this Interface patch.

    Classic, PTR, and other flavors are ignored. An older patch is never used
    as a fallback. When version types are unavailable, multiple type IDs for
    the same patch name fail closed.
    """
    if parse_patch_tuple(desired_patch) is None:
        raise ValueError(f"Invalid retail patch '{desired_patch}'")

    retail_type_ids = curseforge_retail_type_ids(version_types)
    candidates = []
    for version in versions or []:
        if not isinstance(version, dict):
            continue
        name = str(version.get("name") or "").strip()
        if name != desired_patch:
            continue
        type_id = _curseforge_type_id(version)
        if retail_type_ids and type_id not in retail_type_ids:
            continue
        if version.get("id") is None:
            continue
        candidates.append(version)

    if not candidates:
        raise ValueError(
            f"CurseForge does not currently advertise Retail patch '{desired_patch}'. "
            "Live publishing requires an exact Retail catalog match and will not "
            "claim compatibility with an older patch or a Classic/PTR version."
        )

    if not retail_type_ids:
        type_ids = {_curseforge_type_id(version) for version in candidates}
        if len(type_ids) > 1:
            rendered = ", ".join(str(type_id) for type_id in sorted(type_ids, key=str))
            raise ValueError(
                f"CurseForge advertises '{desired_patch}' under multiple game version types "
                f"({rendered}) and the Retail type could not be identified. "
                "Refusing to publish incorrect compatibility metadata."
            )

    ids = {version.get("id") for version in candidates}
    if len(ids) != 1:
        raise ValueError(
            f"CurseForge returned multiple Retail game version IDs for '{desired_patch}'. "
            "Refusing to guess."
        )
    chosen = candidates[0]
    return int(chosen["id"]), str(chosen["name"]), "exact"


def build_curseforge_metadata(version, release_type, changelog, game_version_id, game_version_name):
    """Build the JSON object CurseForge expects in the multipart metadata field."""
    if release_type not in CURSEFORGE_RELEASE_TYPES:
        raise ValueError(f"Invalid CurseForge release type '{release_type}'")
    if type(game_version_id) is not int or game_version_id <= 0:
        raise ValueError(f"Invalid CurseForge game version ID '{game_version_id}'")
    if not game_version_name:
        raise ValueError("CurseForge game version name is required")
    return {
        "changelog": changelog or "",
        "changelogType": "markdown",
        "displayName": version,
        "gameVersions": [game_version_id],
        "gameVersionNames": [game_version_name],
        "releaseType": release_type,
    }


def curseforge_file_is_exact_release(file_obj, *, version, zip_name):
    """Return True when a listed file is this exact Spectrum version or zip name."""
    if not isinstance(file_obj, dict):
        return False
    exact = {version, zip_name}
    for key in ("fileName", "filename", "name", "displayName"):
        value = file_obj.get(key)
        if isinstance(value, str) and value.strip() in exact:
            return True
    return False


def is_existing_curseforge_release(status, body):
    """Return True only when the response clearly says this file already exists.

    A generic HTTP 409 is not treated as proof of an existing release.
    """
    if status not in (400, 409, 422):
        return False
    text = (body or "").lower()
    return any(phrase in text for phrase in CURSEFORGE_DUPLICATE_PHRASES)


def find_existing_curseforge_release(project_id, version, zip_name, token, *, opener=None):
    """Look for an exact existing file before uploading.

    Returns one of:
    - ("found", file)
    - ("absent", None)
    - ("unavailable", reason) when the author API does not provide a usable list
    - ("error", summary) for authentication failures
    """
    status, body, payload = fetch_curseforge_json(
        f"projects/{project_id}/files",
        token,
        timeout=CURSEFORGE_CATALOG_TIMEOUT_SECONDS,
        opener=opener,
    )
    summary = (
        sanitize_output(body or "network error")
        if status is None
        else summarize_wago_http_error(status, body)
    )
    if status in (401, 403):
        return "error", summary
    if status != 200 or payload is None:
        return "unavailable", summary
    files = curseforge_object_list(payload)
    if files is None:
        return "unavailable", "file list response was not a list"
    for file_obj in files:
        if curseforge_file_is_exact_release(file_obj, version=version, zip_name=zip_name):
            return "found", file_obj
    return "absent", None


def report_curseforge_upload_failure(status, body, project_id):
    """Print a credential-free CurseForge upload failure. Return 'duplicate' when proven."""
    if is_existing_curseforge_release(status, body):
        return "duplicate"
    summary = (
        sanitize_output(body or "network error")
        if status is None
        else summarize_wago_http_error(status, body)
    )
    if status is None:
        print(f"::error ::CurseForge network error ({summary})")
    elif status in (401, 403):
        print(f"::error ::CurseForge authentication failed ({summary})")
    elif status == 404:
        print(
            f"::error ::CurseForge project '{project_id}' was not found or is not authorized ({summary})"
        )
    elif status == 409:
        print(
            "::error ::CurseForge returned HTTP 409 without a clear already-exists "
            f"indication ({summary})"
        )
    elif status in (400, 422):
        print(f"::error ::CurseForge rejected the release metadata or file ({summary})")
    elif status >= 500:
        print(f"::error ::CurseForge server error ({summary})")
    else:
        print(f"::error ::CurseForge upload returned unexpected status ({summary})")
    return None


def build_curseforge_publish_plan(
    *,
    version,
    classification,
    addon_name,
    interface,
    zip_path,
    changelog,
    require_game_version,
    versions=None,
    version_types=None,
):
    """Build a CurseForge upload plan from local release metadata."""
    project_id = get_curseforge_project_id(addon_name)
    if not project_id:
        return None

    release_type = classification.curseforge_release_type
    if release_type not in CURSEFORGE_RELEASE_TYPES:
        print(f"::error ::Invalid CurseForge release type '{release_type}'")
        return None

    try:
        retail_patch = interface_to_retail_patch(interface)
    except ValueError as error:
        print(f"::error ::{error}")
        return None

    game_version_id = None
    game_version_name = None
    patch_match = None
    if require_game_version:
        if versions is None:
            print(
                "::error ::Could not load CurseForge's Retail game-version catalog. "
                f"Requested patch '{retail_patch}' cannot be verified."
            )
            return None
        try:
            game_version_id, game_version_name, patch_match = select_curseforge_retail_game_version(
                retail_patch,
                versions,
                version_types,
            )
        except ValueError as error:
            print(f"::error ::{error}")
            return None

    return CurseForgePublishPlan(
        project_id=project_id,
        version=version,
        release_type=release_type,
        retail_patch=retail_patch,
        game_version_id=game_version_id,
        game_version_name=game_version_name,
        patch_match=patch_match,
        changelog=changelog,
        changelog_source=CURSEFORGE_CHANGELOG_SOURCE,
        zip_path=Path(zip_path),
        endpoint=curseforge_upload_endpoint(project_id),
        action="upload",
    )


def resolve_curseforge_publish_plan(
    *,
    version,
    classification,
    addon_name,
    interface,
    zip_path,
    changelog,
    dry_run,
    opener=None,
):
    """Build a CurseForge plan. Live runs resolve the Retail game version; dry-run does not call CurseForge."""
    if dry_run:
        return build_curseforge_publish_plan(
            version=version,
            classification=classification,
            addon_name=addon_name,
            interface=interface,
            zip_path=zip_path,
            changelog=changelog,
            require_game_version=False,
        )

    token = get_curseforge_api_token(required=True)
    if not token:
        return None
    versions, version_types = load_curseforge_catalog(token, opener=opener)
    if versions is None:
        return None
    return build_curseforge_publish_plan(
        version=version,
        classification=classification,
        addon_name=addon_name,
        interface=interface,
        zip_path=zip_path,
        changelog=changelog,
        require_game_version=True,
        versions=versions,
        version_types=version_types,
    )


def log_curseforge_plan(plan, *, dry_run=False):
    """Log non-secret CurseForge publish state."""
    prefix = (
        "[publish-release] DRY RUN - Would upload to CurseForge:"
        if dry_run
        else "[publish-release] CurseForge upload:"
    )
    print(prefix)
    print(f"  CurseForge project: {plan.project_id}")
    print(f"  Release type: {plan.release_type}")
    print(f"  Retail version: {plan.retail_patch}")
    if plan.game_version_id is None:
        print("  CurseForge game version: resolved during live publish")
    else:
        print(
            f"  CurseForge game version: {plan.game_version_name} "
            f"(id {plan.game_version_id}, {plan.patch_match})"
        )
    print(f"  Artifact: {plan.zip_path.name}")
    print(f"  Changelog source: {plan.changelog_source}")
    print(f"  Action: {plan.action}")
    if dry_run:
        print("  Authorization: not sent (dry-run)")
    else:
        print(f"  Endpoint: POST {plan.endpoint}")
        print("  Authorization: X-Api-Token <redacted>")


def publish_to_curseforge(plan, *, dry_run=False, opener=None):
    """Upload the canonical zip with CurseForge's documented multipart Upload API."""
    if dry_run:
        log_curseforge_plan(plan, dry_run=True)
        return "dry-run"

    token = get_curseforge_api_token(required=True)
    if not token:
        return None
    if plan.game_version_id is None or not plan.game_version_name:
        print("::error ::CurseForge Retail game version was not resolved")
        return None
    if not plan.zip_path.exists():
        print(f"::error ::CurseForge artifact does not exist: {plan.zip_path}")
        return None

    lookup, detail = find_existing_curseforge_release(
        plan.project_id,
        plan.version,
        plan.zip_path.name,
        token,
        opener=opener,
    )
    if lookup == "error":
        print(f"::error ::CurseForge authentication failed while checking existing files ({detail})")
        return None
    if lookup == "found":
        print(
            "[publish-release] ✓ CurseForge already has this exact version; "
            "treating as success without uploading a duplicate"
        )
        return "already-exists"
    if lookup == "unavailable":
        print(
            "[publish-release] CurseForge file list is unavailable "
            f"({detail}). The documented Upload API has no guaranteed list-files "
            "call, so an exact existing file is also recognized from an explicit "
            "duplicate upload response. A generic conflict is still a failure."
        )

    try:
        metadata = build_curseforge_metadata(
            plan.version,
            plan.release_type,
            plan.changelog,
            plan.game_version_id,
            plan.game_version_name,
        )
    except ValueError as error:
        print(f"::error ::{error}")
        return None

    body, content_type = encode_multipart_form(
        {"metadata": json.dumps(metadata)},
        {"file": plan.zip_path},
    )
    headers = curseforge_auth_headers(token)
    headers["Content-Type"] = content_type
    request = urllib_request.Request(
        plan.endpoint,
        data=body,
        headers=headers,
        method="POST",
    )
    log_curseforge_plan(plan, dry_run=False)
    urlopen = opener or urllib_request.urlopen

    try:
        with urlopen(request, timeout=CURSEFORGE_UPLOAD_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            response_body = response.read().decode("utf-8", errors="replace")
    except urllib_error.HTTPError as error:
        status = error.code
        response_body = read_http_error_body(error)
        outcome = report_curseforge_upload_failure(status, response_body, plan.project_id)
        if outcome == "duplicate":
            summary = summarize_wago_http_error(status, response_body)
            print(
                "[publish-release] ✓ CurseForge already has this version; "
                f"treating as success ({summary})"
            )
            return "already-exists"
        return None
    except (urllib_error.URLError, TimeoutError, OSError) as error:
        print(f"::error ::CurseForge network error ({sanitize_output(str(error))})")
        return None

    if status in (200, 201):
        print(f"[publish-release] ✓ CurseForge publication succeeded (HTTP {status})")
        return "uploaded"

    outcome = report_curseforge_upload_failure(status, response_body, plan.project_id)
    if outcome == "duplicate":
        summary = summarize_wago_http_error(status, response_body)
        print(
            "[publish-release] ✓ CurseForge already has this version; "
            f"treating as success ({summary})"
        )
        return "already-exists"
    return None


def log_destination_results(*, github_ok, curseforge_ok, wago_ok):
    """Report which release destinations succeeded. Successful publishes stay published."""
    if not github_ok:
        print(
            "[publish-release] GitHub release failed. "
            "CurseForge and Wago were not attempted."
        )
        return

    curseforge_state = "succeeded" if curseforge_ok else "failed"
    wago_state = "succeeded" if wago_ok else "failed"
    print(
        "[publish-release] Destination results: "
        f"GitHub succeeded, CurseForge {curseforge_state}, Wago {wago_state}."
    )
    if curseforge_ok and wago_ok:
        return
    print(
        "[publish-release] Successful destinations were kept. "
        "Rerun this script for the same version to retry the failed destination. "
        "An exact existing CurseForge or Wago release is treated as success and is not uploaded again. "
        "Do not delete GitHub, CurseForge, or Wago releases that already succeeded."
    )


def _attempt_curseforge(
    *,
    version,
    classification,
    addon_name,
    interface,
    zip_path,
    changelog,
):
    plan = resolve_curseforge_publish_plan(
        version=version,
        classification=classification,
        addon_name=addon_name,
        interface=interface,
        zip_path=zip_path,
        changelog=changelog,
        dry_run=False,
    )
    if not plan:
        return False
    action = publish_to_curseforge(plan, dry_run=False)
    if not action:
        return False
    print(f"[publish-release] CurseForge publication action: {action}")
    return True


def _attempt_wago(
    *,
    version,
    classification,
    addon_name,
    interface,
    zip_path,
    changelog,
):
    plan = resolve_wago_publish_plan(
        version=version,
        classification=classification,
        addon_name=addon_name,
        interface=interface,
        zip_path=zip_path,
        changelog=changelog,
    )
    if not plan:
        return False
    log_wago_summary(plan)
    action = publish_to_wago(plan, dry_run=False)
    if not action:
        return False
    print(f"[publish-release] Wago publication action: {action}")
    return True


def publish_github_then_external(
    *,
    version,
    classification,
    addon_name,
    interface,
    zip_path,
    json_path,
    notes,
    notes_path,
    repo,
    dry_run,
):
    """Publish GitHub first. CurseForge and Wago then run independently.

    A failure at either downstream destination does not delete another
    successful destination and does not skip the other downstream attempt.
    Dry-run validates both external plans before simulating GitHub and does
    not send CurseForge or Wago credentials.
    """
    if dry_run:
        curseforge_plan = resolve_curseforge_publish_plan(
            version=version,
            classification=classification,
            addon_name=addon_name,
            interface=interface,
            zip_path=zip_path,
            changelog=notes,
            dry_run=True,
        )
        wago_plan = resolve_wago_publish_plan(
            version=version,
            classification=classification,
            addon_name=addon_name,
            interface=interface,
            zip_path=zip_path,
            changelog=notes,
        )
        if curseforge_plan:
            print(f"[publish-release] CurseForge project ID: {curseforge_plan.project_id}")
            print(f"[publish-release] CurseForge release type: {curseforge_plan.release_type}")
            print(f"[publish-release] Retail version: {curseforge_plan.retail_patch}")
        if wago_plan:
            log_wago_summary(wago_plan)
        if not curseforge_plan or not wago_plan:
            return False

        github_action = create_github_release(
            version,
            zip_path,
            json_path,
            repo,
            classification,
            notes_path,
            dry_run=True,
        )
        if not github_action:
            return False
        print(f"[publish-release] GitHub release action: {github_action}")
        curseforge_action = publish_to_curseforge(curseforge_plan, dry_run=True)
        wago_action = publish_to_wago(wago_plan, dry_run=True)
        if not curseforge_action or not wago_action:
            return False
        print(f"[publish-release] CurseForge publication action: {curseforge_action}")
        print(f"[publish-release] Wago publication action: {wago_action}")
        return True

    github_action = create_github_release(
        version,
        zip_path,
        json_path,
        repo,
        classification,
        notes_path,
        dry_run=False,
    )
    if not github_action:
        log_destination_results(github_ok=False, curseforge_ok=False, wago_ok=False)
        return False
    print(f"[publish-release] GitHub release action: {github_action}")

    curseforge_ok = _attempt_curseforge(
        version=version,
        classification=classification,
        addon_name=addon_name,
        interface=interface,
        zip_path=zip_path,
        changelog=notes,
    )
    wago_ok = _attempt_wago(
        version=version,
        classification=classification,
        addon_name=addon_name,
        interface=interface,
        zip_path=zip_path,
        changelog=notes,
    )
    log_destination_results(
        github_ok=True,
        curseforge_ok=curseforge_ok,
        wago_ok=wago_ok,
    )
    return curseforge_ok and wago_ok


def main():
    parser = argparse.ArgumentParser(
        description="Package addon and create GitHub, CurseForge, and Wago releases"
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
    print(f"[publish-release] CurseForge release type: {classification.curseforge_release_type}")
    
    # Construct zip filename
    zip_filename = f"{args.addon_name}-{args.version}.zip"
    
    # Create release.json
    json_path = create_release_json(
        args.version,
        args.interface,
        args.addon_name,
        zip_filename
    )
    
    if not requested_version_matches_packaged_toc(args.addon_name, args.version):
        sys.exit(1)

    # Create zip
    zip_path = create_addon_zip(args.addon_name, args.version)
    if not zip_path:
        sys.exit(1)

    notes = build_release_notes(args.version, args.repo, classification)
    notes_path = write_release_notes(notes)
    print(f"[publish-release] ZIP artifact: {zip_path.name}")

    published = publish_github_then_external(
        version=args.version,
        classification=classification,
        addon_name=args.addon_name,
        interface=args.interface,
        zip_path=zip_path,
        json_path=json_path,
        notes=notes,
        notes_path=notes_path,
        repo=args.repo,
        dry_run=args.dry_run,
    )
    if not published:
        sys.exit(1)

    print("[publish-release] ✅ Release published successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
