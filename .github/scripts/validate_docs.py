"""Validate MkDocs documentation and its code-facing references."""

import importlib.util
import re
import subprocess
import sys
from pathlib import Path


def _load_blizzard_api():
    """Load the sibling Blizzard API helper without treating scripts as a package."""
    module_path = Path(__file__).resolve().parent / "blizzard_api.py"
    spec = importlib.util.spec_from_file_location("blizzard_api", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


blizzard_api = _load_blizzard_api()
interface_to_display = blizzard_api.interface_to_display

STALE_PATTERNS = {
    r"/sfdebug\b": "Use '/sf debug', not the removed '/sfdebug' command.",
    r"\bSF\.Settings\.(?:Store|Schema|Apply|Registry)\b": (
        "Use the current SF.SettingsStore/SF.SettingsSchema/SF.SettingsApply/SF.SettingsUI APIs."
    ),
    r"\bPages/Main\.lua\b": "The current general settings page is Pages/General.lua.",
    r"\bmodules/(?:(?-i:Core)|LootProfiles|settings_ui)\.lua\b": (
        "This references a removed or incorrectly-cased addon module."
    ),
    r"\blinter\.ya?ml\b": "There is no standalone linter workflow.",
    r"\.github/scripts/README\.md\b": "The referenced scripts README does not exist.",
    r"ESC\s*(?:→|->)\s*Interface\s*(?:→|->)\s*AddOns": (
        "Blizzard Settings registration is disabled; direct users to /sf."
    ),
}

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*]\(([^)]+)\)")
NAV_PAGE_RE = re.compile(r"^\s*-\s+[^:]+:\s+([^\s#]+\.md)\s*$", re.MULTILINE)
REPOSITORY_REFERENCE_RE = re.compile(
    r"`((?:\.github/(?:scripts|workflows)|assets)/[A-Za-z0-9_./-]+\.(?:py|ya?ml|json))`"
)
REGISTERED_COMMAND_RE = re.compile(r"RegisterSlashCommand\(\s*[\"']([^\"']+)[\"']")
SLASH_ALIAS_RE = re.compile(r"SLASH_[A-Z0-9_]+\d+\s*=\s*[\"'](/[^\"']+)[\"']")


def line_number(text, offset):
    """Return the one-based line number for a character offset."""
    return text.count("\n", 0, offset) + 1


def documentation_files(repo_root):
    """Return Markdown files that make up public repository documentation."""
    files = sorted((repo_root / "docs").rglob("*.md"))
    readme = repo_root / "README.md"
    if readme.exists():
        files.append(readme)
    return files


def validate_navigation(repo_root):
    """Require every documentation page to exist and appear in MkDocs navigation."""
    docs_root = repo_root / "docs"
    config_text = (repo_root / "mkdocs.yml").read_text(encoding="utf-8")
    nav_pages = set(NAV_PAGE_RE.findall(config_text))
    actual_pages = {
        path.relative_to(docs_root).as_posix()
        for path in docs_root.rglob("*.md")
    }

    errors = []
    for page in sorted(nav_pages - actual_pages):
        errors.append(f"mkdocs.yml: navigation target does not exist: docs/{page}")
    for page in sorted(actual_pages - nav_pages):
        errors.append(f"docs/{page}: page is not included in mkdocs.yml navigation")
    return errors


def normalize_link_target(raw_target):
    """Remove optional Markdown titles and angle brackets from a link target."""
    target = raw_target.strip()
    if target.startswith("<") and ">" in target:
        return target[1:target.index(">")]
    if ' "' in target:
        target = target.split(' "', 1)[0]
    if " '" in target:
        target = target.split(" '", 1)[0]
    return target


def validate_local_links(repo_root):
    """Require relative Markdown links and images to resolve on disk."""
    errors = []
    scheme_re = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")

    for page in documentation_files(repo_root):
        text = page.read_text(encoding="utf-8")
        for match in MARKDOWN_LINK_RE.finditer(text):
            target = normalize_link_target(match.group(1)).split("#", 1)[0]
            if (
                not target
                or target.startswith(("#", "/", "//"))
                or scheme_re.match(target)
            ):
                continue
            resolved = (page.parent / target).resolve()
            if not resolved.exists():
                relative_page = page.relative_to(repo_root).as_posix()
                errors.append(
                    f"{relative_page}:{line_number(text, match.start())}: "
                    f"local target does not exist: {target}"
                )
    return errors


def validate_stale_content(repo_root):
    """Reject known obsolete APIs, commands, paths, and access instructions."""
    errors = []
    compiled = [
        (re.compile(pattern, re.IGNORECASE), message)
        for pattern, message in STALE_PATTERNS.items()
    ]

    for page in documentation_files(repo_root):
        text = page.read_text(encoding="utf-8")
        for pattern, message in compiled:
            for match in pattern.finditer(text):
                relative_page = page.relative_to(repo_root).as_posix()
                errors.append(
                    f"{relative_page}:{line_number(text, match.start())}: {message}"
                )
    return errors


def validate_repository_references(repo_root):
    """Require explicitly linked workflow, script, and asset paths to exist."""
    errors = []
    for page in documentation_files(repo_root):
        text = page.read_text(encoding="utf-8")
        for match in REPOSITORY_REFERENCE_RE.finditer(text):
            target = match.group(1)
            if not (repo_root / target).exists():
                relative_page = page.relative_to(repo_root).as_posix()
                errors.append(
                    f"{relative_page}:{line_number(text, match.start())}: "
                    f"repository reference does not exist: {target}"
                )
    return errors


def read_toc_field(toc_text, field):
    """Read a metadata field from the authoritative TOC text."""
    match = re.search(
        rf"^##\s+{re.escape(field)}:\s*(\S+)\s*$",
        toc_text,
        re.MULTILINE,
    )
    return match.group(1) if match else None


def validate_readme_badges(repo_root):
    """Keep generated README version/interface badges aligned with the TOC.

    The Interface badge uses the human-readable form of the 6-digit TOC value
    (for example 120100 becomes 12.1.0).
    """
    toc_text = (repo_root / "SpectrumFederation/SpectrumFederation.toc").read_text(
        encoding="utf-8"
    )
    readme_text = (repo_root / "README.md").read_text(encoding="utf-8")
    interface = read_toc_field(toc_text, "Interface")
    version = read_toc_field(toc_text, "Version")
    errors = []

    is_beta_version = bool(version and "-beta." in version)

    if not interface:
        errors.append(
            "SpectrumFederation/SpectrumFederation.toc: missing ## Interface metadata"
        )
    elif "badge/Interface-" not in readme_text:
        errors.append("README.md: missing automation-compatible Interface badge")
    else:
        try:
            interface_display = interface_to_display(interface)
        except ValueError:
            errors.append(
                "SpectrumFederation/SpectrumFederation.toc: "
                f"Interface '{interface}' is not a 6-digit value"
            )
        else:
            if (
                not is_beta_version
                and f"badge/Interface-{interface_display}-" not in readme_text
            ):
                errors.append(
                    "README.md: Interface badge does not match TOC value "
                    f"{interface} ({interface_display})"
                )

    if not version:
        errors.append(
            "SpectrumFederation/SpectrumFederation.toc: missing ## Version metadata"
        )
    else:
        escaped_version = version.replace("-", "--")
        if "badge/Version-" not in readme_text:
            errors.append("README.md: missing automation-compatible Version badge")
        elif (
            not is_beta_version
            and f"badge/Version-{escaped_version}-brightgreen" not in readme_text
        ):
            errors.append(
                f"README.md: Version badge does not match TOC value {version}"
            )
    return errors


def validate_slash_command_reference(repo_root):
    """Require every registered command and diagnostic alias in the reference."""
    addon_roots = [repo_root / "SpectrumFederation"]
    for child_name in (
        "SpectrumFederation_CursedSurgeTracker",
        "SpectrumFederation_RCLootCouncilCapture",
    ):
        child_root = repo_root / child_name
        if child_root.exists():
            addon_roots.append(child_root)
    commands = set()
    aliases = set()
    for addon_root in addon_roots:
        for source in addon_root.rglob("*.lua"):
            source_text = source.read_text(encoding="utf-8")
            commands.update(
                REGISTERED_COMMAND_RE.findall(source_text)
            )
            aliases.update(SLASH_ALIAS_RE.findall(source_text))
    reference = (
        repo_root / "docs/reference/slash-commands.md"
    ).read_text(encoding="utf-8").lower()
    errors = []

    for command in sorted(commands):
        rendered = f"/sf {command.lower()}"
        if rendered not in reference:
            errors.append(
                "docs/reference/slash-commands.md: "
                f"registered command is undocumented: {rendered}"
            )
    for alias in sorted(aliases):
        if alias.lower() not in reference:
            errors.append(
                "docs/reference/slash-commands.md: "
                f"registered diagnostic alias is undocumented: {alias}"
            )
    return errors


def validate_known_limitations(repo_root):
    """Keep visible implementation placeholders documented until completed."""
    settings_page = (
        repo_root / "SpectrumFederation/modules/UI/Settings/Pages/LootHelper.lua"
    ).read_text(encoding="utf-8")
    store_text = (
        repo_root / "SpectrumFederation/modules/Settings/Store.lua"
    ).read_text(encoding="utf-8")
    user_docs = "\n".join(
        [
            (repo_root / "docs/settings-ui.md").read_text(encoding="utf-8"),
            (repo_root / "docs/features/sync-sessions.md").read_text(
                encoding="utf-8"
            ),
        ]
    )
    errors = []

    if 'return false, "Not implemented"' in store_text and not re.search(
        r"Reset Current Profile.{0,100}(?:placeholder|not implemented|nonfunctional)",
        user_docs,
        re.IGNORECASE | re.DOTALL,
    ):
        errors.append(
            "docs/settings-ui.md: "
            "the visible Reset Current Profile placeholder must be documented"
        )

    if "Stub: Trigger Raid-Wide Sync" in settings_page and not re.search(
        r"Trigger Raid-Wide Sync.{0,100}(?:placeholder|not implemented|does not)",
        user_docs,
        re.IGNORECASE | re.DOTALL,
    ):
        errors.append(
            "docs/settings-ui.md: "
            "the visible Trigger Raid-Wide Sync placeholder must be documented"
        )
    return errors


def run_guardrails(repo_root):
    """Run repository-specific documentation guardrails."""
    checks = [
        ("navigation coverage", validate_navigation),
        ("local links and assets", validate_local_links),
        ("stale documentation patterns", validate_stale_content),
        ("repository references", validate_repository_references),
        ("README metadata badges", validate_readme_badges),
        ("slash command reference", validate_slash_command_reference),
        ("known UI limitations", validate_known_limitations),
    ]
    errors = []
    for name, check in checks:
        check_errors = check(repo_root)
        if check_errors:
            print(f"[validate-docs] ✗ {name}")
            errors.extend(check_errors)
        else:
            print(f"[validate-docs] ✓ {name}")
    return errors


def run_mkdocs(repo_root):
    """Build MkDocs in strict mode and return its exit code."""
    try:
        result = subprocess.run(
            ["mkdocs", "build", "--clean", "--strict"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        print(
            "::error::mkdocs command not found. "
            "Install with: pip install -r requirements-docs.txt"
        )
        return 1

    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    return result.returncode


def main():
    """Run repository guardrails followed by a strict MkDocs build."""
    print("[validate-docs] Validating MkDocs documentation...")
    repo_root = Path(__file__).parent.parent.parent

    try:
        errors = run_guardrails(repo_root)
        if errors:
            for error in errors:
                print(f"::error::{error}")
            print(
                "[validate-docs] ✗ "
                f"Documentation guardrails found {len(errors)} error(s)"
            )
            return 1

        if run_mkdocs(repo_root) != 0:
            print("::error::MkDocs build failed with errors")
            print("[validate-docs] ✗ Documentation build failed")
            return 1

        print("[validate-docs] ✓ Documentation guardrails and strict build passed")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"::error::Unexpected error during validation: {error}")
        print("[validate-docs] ✗ Validation failed")
        return 1


if __name__ == "__main__":
    sys.exit(main())
