"""Classify promotion and PR changes from git state, not from AI.

Determines what kind of beta→main promotion (or pull request) this is by
diffing an immutable base/head pair and matching paths against the real
packaging and MkDocs layouts.

AI is not used here. Downstream workflows should consume these flags rather
than re-implementing path filters.
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import validate_packaging

PARENT_ADDON_NAME = "SpectrumFederation"
ADDON_ROOTS = (PARENT_ADDON_NAME, *validate_packaging.CHILD_ADDON_NAMES)
ZIP_EXCLUDES = tuple(validate_packaging.ZIP_EXCLUDES)

DOCS_EXACT_PATHS = frozenset({"mkdocs.yml", "requirements-docs.txt"})
DOCS_PREFIXES = ("docs/", "overrides/")
README_PATH = "README.md"
CHANGELOG_PATH = "CHANGELOG.md"
PARENT_TOC_PATH = "SpectrumFederation/SpectrumFederation.toc"
MAX_FILES_PER_CATEGORY = 40
STABLE_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
BETA_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$")
TOC_VERSION_RE = re.compile(r"^## Version:\s*(.+)$", re.MULTILINE | re.IGNORECASE)


def normalize_repo_path(path):
    """Return a POSIX repo-relative path without a leading ./."""
    normalized = (path or "").replace("\\", "/").strip()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized.lstrip("/")


def is_under_addon_root(path):
    """Return True when path is inside a packaged addon directory."""
    normalized = normalize_repo_path(path)
    for root in ADDON_ROOTS:
        if normalized == root or normalized.startswith(f"{root}/"):
            return True
    return False


def is_zip_excluded_path(path):
    """Return True when packaging's zip -x patterns exclude this path."""
    normalized = normalize_repo_path(path)
    if not is_under_addon_root(normalized):
        return False
    return any(
        fnmatch.fnmatch(normalized, pattern) or fnmatch.fnmatch(Path(normalized).name, pattern)
        for pattern in ZIP_EXCLUDES
    )


def is_packaged_addon_path(path):
    """Return True for a file that ships in the addon release zip."""
    normalized = normalize_repo_path(path)
    if not is_under_addon_root(normalized):
        return False
    return not is_zip_excluded_path(normalized)


def is_docs_path(path):
    """Return True for a source file that affects the MkDocs site."""
    normalized = normalize_repo_path(path)
    if normalized in DOCS_EXACT_PATHS:
        return True
    return any(
        normalized == prefix.rstrip("/") or normalized.startswith(prefix)
        for prefix in DOCS_PREFIXES
    )


def is_readme_path(path):
    """Return True for the repository README."""
    return normalize_repo_path(path) == README_PATH


def is_changelog_path(path):
    """Return True for CHANGELOG.md."""
    return normalize_repo_path(path) == CHANGELOG_PATH


def path_category(path):
    """Return the primary classification bucket for a changed path.

    Categories are independent capabilities. A file belongs to one bucket for
    listing; flags are still computed independently from predicates above.
    """
    normalized = normalize_repo_path(path)
    if is_packaged_addon_path(normalized):
        return "addon"
    if is_docs_path(normalized):
        return "docs"
    if is_readme_path(normalized):
        return "readme"
    if is_changelog_path(normalized):
        return "changelog"
    return "infra"


@dataclass
class PromotionScope:
    """Deterministic promotion/PR change classification."""

    files: list[str] = field(default_factory=list)
    promotion_base_sha: str = ""
    promotion_target_sha: str = ""
    promotion_merge_base_sha: str = ""
    addon_files: list[str] = field(default_factory=list)
    docs_files: list[str] = field(default_factory=list)
    readme_files: list[str] = field(default_factory=list)
    changelog_files: list[str] = field(default_factory=list)
    infra_files: list[str] = field(default_factory=list)
    merge_required: bool | None = None

    @property
    def addon_changed(self):
        return bool(self.addon_files)

    @property
    def docs_changed(self):
        return bool(self.docs_files)

    @property
    def readme_changed(self):
        return bool(self.readme_files)

    @property
    def changelog_changed(self):
        return bool(self.changelog_files)

    @property
    def infra_changed(self):
        return bool(self.infra_files)

    @property
    def has_incoming_changes(self):
        return bool(self.files)

    @property
    def target_contained_in_main(self):
        """True when git ancestry says the captured target is already in main.

        Distinct from has_incoming_changes, which is a changed-file classification.
        None when ancestry was not computed (explicit --files mode).
        """
        if self.merge_required is None:
            return None
        return not self.merge_required

    @property
    def release_required(self):
        """Stable addon publishing is warranted only for packaged addon changes."""
        return self.addon_changed

    @property
    def changelog_required(self):
        """Addon-release changelog generation follows release_required."""
        return self.release_required

    @property
    def documentation_deploy_required(self):
        """MkDocs deploy follows MkDocs source changes, not addon releases."""
        return self.docs_changed

    @property
    def readme_work_required(self):
        """Badge/README automation runs for incoming README edits or a release."""
        return self.release_required or self.readme_changed

    @property
    def promotion_type(self):
        """Human-readable label; flags remain the decision source of truth."""
        parts = []
        if self.addon_changed:
            parts.append("addon")
        if self.docs_changed:
            parts.append("documentation")
        if self.readme_changed:
            parts.append("README")
        if self.changelog_changed:
            parts.append("changelog")
        if self.infra_changed:
            parts.append("workflow/infrastructure")
        if not parts:
            return "No downstream-relevant changes"
        return " + ".join(parts)


def classify_files(paths, base_sha="", target_sha="", merge_base_sha=""):
    """Classify an explicit changed-file list into a PromotionScope."""
    seen = set()
    files = []
    for raw in paths:
        normalized = normalize_repo_path(raw)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        files.append(normalized)

    scope = PromotionScope(
        files=files,
        promotion_base_sha=base_sha,
        promotion_target_sha=target_sha,
        promotion_merge_base_sha=merge_base_sha,
    )
    for path in files:
        category = path_category(path)
        getattr(scope, f"{category}_files").append(path)
    return scope


def run_git(args, cwd=None, check=True):
    """Run git and return stripped stdout."""
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "git command failed"
        raise RuntimeError(f"git {' '.join(args)}: {message}")
    return result.stdout.strip()


def resolve_commit(ref, cwd=None):
    """Resolve a ref to a full SHA."""
    return run_git(["rev-parse", ref], cwd=cwd)


def collect_changed_files(base, head, cwd=None):
    """Return changed paths for the promotion range base...head.

    Triple-dot / merge-base semantics are used so independent commits already
    on the base branch are not treated as incoming promotion changes.

    `--no-renames` reports a move as delete plus add so a file leaving the
    packaged addon tree still counts as `addon_changed`.
    """
    merge_base = run_git(["merge-base", base, head], cwd=cwd)
    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", "--no-renames", merge_base, head],
        cwd=cwd,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.decode().strip() or "git diff failed"
        raise RuntimeError(
            f"git diff --name-only -z --no-renames {merge_base} {head}: {message}"
        )
    files = [
        normalize_repo_path(path)
        for path in result.stdout.decode().split("\0")
        if path
    ]
    return files, merge_base


def classify_git_range(base, head, cwd=None):
    """Classify the immutable git range that a promotion or PR should use."""
    base_sha = resolve_commit(base, cwd=cwd)
    head_sha = resolve_commit(head, cwd=cwd)
    files, merge_base_sha = collect_changed_files(base_sha, head_sha, cwd=cwd)
    scope = classify_files(
        files,
        base_sha=base_sha,
        target_sha=head_sha,
        merge_base_sha=merge_base_sha,
    )
    scope.merge_required = promotion_merge_required(head_sha, base_sha, cwd=cwd)
    return scope


def git_is_ancestor(ancestor, descendant, cwd=None):
    """Return True when ancestor is in descendant's history."""
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=cwd,
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


def describe_ref_drift(expected_sha, actual_sha, cwd=None):
    """Return how actual_sha relates to expected_sha: match, advanced, rewound, or diverged."""
    expected_sha = resolve_commit(expected_sha, cwd=cwd)
    actual_sha = resolve_commit(actual_sha, cwd=cwd)
    if expected_sha == actual_sha:
        return "match"
    if git_is_ancestor(expected_sha, actual_sha, cwd=cwd):
        return "advanced"
    if git_is_ancestor(actual_sha, expected_sha, cwd=cwd):
        return "rewound"
    return "diverged"


def _rerun_instruction():
    return "Rerun Promote Beta to Main so scope detection and the merge use the same commits."


def verify_promotion_refs(
    expected_base,
    expected_target,
    current_base,
    current_target,
    cwd=None,
    mode="merge",
    destination=None,
):
    """Return error strings when remote refs drifted from the captured promotion range.

    mode='merge': origin/main and origin/beta must still equal the captured SHAs.
    mode='fast-forward': origin/beta must still equal the captured target, and
    that target must be an ancestor of destination (usually origin/main after
    the promotion merge). Newer beta work is never overwritten.
    """
    expected_base = resolve_commit(expected_base, cwd=cwd)
    expected_target = resolve_commit(expected_target, cwd=cwd)
    current_base = resolve_commit(current_base, cwd=cwd)
    current_target = resolve_commit(current_target, cwd=cwd)
    errors = []

    if mode == "fast-forward":
        beta_drift = describe_ref_drift(expected_target, current_target, cwd=cwd)
        if beta_drift == "advanced":
            errors.append(
                "origin/beta has advanced beyond the captured promotion target "
                f"({expected_target} -> {current_target}). "
                "Refusing to overwrite newer beta work. "
                + _rerun_instruction()
            )
        elif beta_drift != "match":
            errors.append(
                "origin/beta no longer points at the captured promotion target "
                f"({expected_target} -> {current_target}, {beta_drift}). "
                + _rerun_instruction()
            )
        if destination:
            destination = resolve_commit(destination, cwd=cwd)
            if not git_is_ancestor(expected_target, destination, cwd=cwd):
                errors.append(
                    f"Captured promotion target {expected_target} is not an ancestor of "
                    f"{destination}. A fast-forward of beta onto that commit is not possible."
                )
        return errors

    if current_base != expected_base:
        errors.append(
            "origin/main has moved since promotion scope was captured "
            f"({expected_base} -> {current_base}). "
            + _rerun_instruction()
        )
    beta_drift = describe_ref_drift(expected_target, current_target, cwd=cwd)
    if beta_drift == "advanced":
        errors.append(
            "origin/beta has advanced beyond the captured promotion target "
            f"({expected_target} -> {current_target}). "
            "Newer beta work will not be promoted or overwritten. "
            + _rerun_instruction()
        )
    elif beta_drift != "match":
        errors.append(
            "origin/beta no longer points at the captured promotion target "
            f"({expected_target} -> {current_target}, {beta_drift}). "
            + _rerun_instruction()
        )
    return errors


PROMOTION_MERGE_OVERLAY_PATHS = (
    "CHANGELOG.md",
    "README.md",
    "SpectrumFederation/SpectrumFederation.toc",
    "SpectrumFederation_CursedSurgeTracker/SpectrumFederation_CursedSurgeTracker.toc",
    "SpectrumFederation_RCLootCouncilIntegration/SpectrumFederation_RCLootCouncilIntegration.toc",
)


def captured_target_contained_in_main(target, main, cwd=None):
    """Return True when the captured promotion target is already in main's history.

    A commit is an ancestor of itself, so beta == main is contained.
    """
    return git_is_ancestor(target, main, cwd=cwd)


def promotion_merge_required(target, main, cwd=None):
    """Return True when main still needs a merge of the captured target SHA."""
    return not captured_target_contained_in_main(target, main, cwd=cwd)


def plan_promotion_git_mutation(target, main, cwd=None):
    """Return whether to merge/overlay the captured target onto verified main.

    Ancestry decides this, not has_incoming_changes. When the target is already
    contained in main, overlays must not restore older beta copies of generated
    CHANGELOG/README/TOC files.
    """
    target_sha = resolve_commit(target, cwd=cwd)
    main_sha = resolve_commit(main, cwd=cwd)
    merge_required = promotion_merge_required(target_sha, main_sha, cwd=cwd)
    return {
        "merge_required": merge_required,
        "target_contained_in_main": not merge_required,
        "target_sha": target_sha,
        "main_sha": main_sha,
        "create_merge_commit": merge_required,
        "overlay_captured_target_files": (
            list(PROMOTION_MERGE_OVERLAY_PATHS) if merge_required else []
        ),
    }


def read_toc_version_from_ref(ref, cwd=None, path=PARENT_TOC_PATH):
    """Return the ## Version value from a TOC blob at ref."""
    content = run_git(["show", f"{ref}:{path}"], cwd=cwd)
    match = TOC_VERSION_RE.search(content)
    if not match:
        raise RuntimeError(f"No '## Version:' line in {path} at {ref}")
    return match.group(1).strip()


def is_stable_toc_version(version):
    """Return True for a stable X.Y.Z TOC version."""
    return bool(STABLE_VERSION_RE.fullmatch((version or "").strip()))


def is_beta_toc_version(version):
    """Return True for an X.Y.Z-beta.N TOC version."""
    return bool(BETA_VERSION_RE.fullmatch((version or "").strip()))


def validate_promotion_toc_versions(
    release_required,
    merge_required,
    target_ref,
    base_ref,
    cwd=None,
):
    """Return error strings when TOC versions do not match the promotion case.

    release_required selects the expected *shape* of the version.
    merge_required selects which captured SHA is authoritative:
    - merge required: the captured beta target will be merged/overlaid
    - no merge: captured main is preserved, so main's TOC is authoritative
    """
    errors = []
    try:
        if release_required:
            version = read_toc_version_from_ref(target_ref, cwd=cwd)
            if not is_beta_toc_version(version):
                errors.append(
                    "Addon release requires captured beta TOC version X.Y.Z-beta.N, "
                    f"got {version!r} at {target_ref}."
                )
            return errors

        if merge_required:
            version = read_toc_version_from_ref(target_ref, cwd=cwd)
            if not is_stable_toc_version(version):
                errors.append(
                    "A non-addon promotion that still merges into main must keep a stable "
                    f"X.Y.Z TOC version on the captured beta target, got {version!r}. "
                    "Beta appears to contain stale release metadata from an incomplete "
                    "previous addon promotion. Synchronize beta to main before merging "
                    "new non-addon work so a prerelease TOC is not restored onto main."
                )
            return errors

        version = read_toc_version_from_ref(base_ref, cwd=cwd)
        if not is_stable_toc_version(version):
            errors.append(
                "No-op recovery requires the captured main TOC version to be stable "
                f"X.Y.Z, got {version!r} at {base_ref}."
            )
    except RuntimeError as exc:
        errors.append(str(exc))
    return errors


def bool_text(value):
    """Return GitHub Actions-friendly true/false."""
    return "true" if value else "false"


def yes_no(value):
    """Return a Yes/No label for summaries."""
    return "Yes" if value else "No"


def format_file_group(title, files):
    """Return a short categorized file list for summaries."""
    lines = [f"{title}:"]
    if not files:
        lines.append("- none")
        return "\n".join(lines)
    shown = files[:MAX_FILES_PER_CATEGORY]
    lines.extend(f"- {path}" for path in shown)
    remaining = len(files) - len(shown)
    if remaining > 0:
        lines.append(f"- ... and {remaining} more")
    return "\n".join(lines)


def format_scope_report(scope):
    """Return the maintainer-facing promotion-scope summary."""
    lines = [
        "Promotion Scope",
        "---------------------------------",
        f"Base SHA:                   {scope.promotion_base_sha or '(file list)'}",
        f"Target SHA:                 {scope.promotion_target_sha or '(file list)'}",
        f"Merge-base SHA:             {scope.promotion_merge_base_sha or '(file list)'}",
        f"Promotion type:             {scope.promotion_type}",
        f"Incoming changes:           {yes_no(scope.has_incoming_changes)} ({len(scope.files)} files)",
        f"Merge commit required:      {yes_no(scope.merge_required) if scope.merge_required is not None else '(file list)'}",
        f"Addon changes:              {yes_no(scope.addon_changed)}",
        f"Documentation changes:      {yes_no(scope.docs_changed)}",
        f"README changed:             {yes_no(scope.readme_changed)}",
        f"Changelog changed:          {yes_no(scope.changelog_changed)}",
        f"Infrastructure changes:     {yes_no(scope.infra_changed)}",
        f"README work required:       {yes_no(scope.readme_work_required)}",
        f"Changelog required:         {yes_no(scope.changelog_required)}",
        f"Stable addon release:       {yes_no(scope.release_required)}",
        f"Documentation deployment:   {yes_no(scope.documentation_deploy_required)}",
        "",
        format_file_group("Addon", scope.addon_files),
        "",
        format_file_group("Documentation", scope.docs_files),
        "",
        format_file_group("README", scope.readme_files),
        "",
        format_file_group("Changelog", scope.changelog_files),
        "",
        format_file_group("Workflow/Infrastructure", scope.infra_files),
    ]
    return "\n".join(lines) + "\n"


def write_github_output(scope, output_path):
    """Write classification flags for GitHub Actions job outputs."""
    path = Path(output_path)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"promotion_base_sha={scope.promotion_base_sha}\n")
        handle.write(f"promotion_target_sha={scope.promotion_target_sha}\n")
        handle.write(f"promotion_merge_base_sha={scope.promotion_merge_base_sha}\n")
        handle.write(f"promotion_type={scope.promotion_type}\n")
        handle.write(f"addon_changed={bool_text(scope.addon_changed)}\n")
        handle.write(f"docs_changed={bool_text(scope.docs_changed)}\n")
        handle.write(f"readme_changed={bool_text(scope.readme_changed)}\n")
        handle.write(f"changelog_changed={bool_text(scope.changelog_changed)}\n")
        handle.write(f"infra_changed={bool_text(scope.infra_changed)}\n")
        handle.write(f"release_required={bool_text(scope.release_required)}\n")
        handle.write(f"changelog_required={bool_text(scope.changelog_required)}\n")
        handle.write(
            "documentation_deploy_required="
            f"{bool_text(scope.documentation_deploy_required)}\n"
        )
        handle.write(f"readme_work_required={bool_text(scope.readme_work_required)}\n")
        handle.write(f"has_incoming_changes={bool_text(scope.has_incoming_changes)}\n")
        if scope.merge_required is not None:
            handle.write(f"merge_required={bool_text(scope.merge_required)}\n")
            handle.write(
                "target_contained_in_main="
                f"{bool_text(scope.target_contained_in_main)}\n"
            )


def job_outcome_ok(required, result):
    """Return True when a job result matches the required/optional expectation.

    Required jobs must succeed. Conditional jobs must be skipped when they are
    not required. Unexpected success is a mismatch, not a pass.
    """
    result = (result or "").strip().lower()
    if required:
        return result == "success"
    return result == "skipped"


def verify_promotion_outcomes(expectations):
    """Return error strings for required jobs that did not run as expected.

    `expectations` is a list of (name, required, result) tuples.
    """
    errors = []
    for name, required, result in expectations:
        if job_outcome_ok(required, result):
            continue
        if required:
            errors.append(
                f"{name} was required but result was '{result or 'missing'}'"
            )
        else:
            errors.append(
                f"{name} was not required but ran with result '{result or 'missing'}'"
            )
    return errors


def parse_bool_flag(value):
    """Parse a true/false GitHub output string."""
    normalized = (value or "").strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise ValueError(f"Expected true or false, got {value!r}")


def build_parser():
    """Return the CLI parser."""
    parser = argparse.ArgumentParser(
        description="Classify promotion or pull-request changed files."
    )
    parser.add_argument(
        "--base",
        help="Base ref or SHA (promotion: origin/main; PR: base SHA)",
    )
    parser.add_argument(
        "--head",
        help="Head ref or SHA (promotion: beta HEAD; PR: head SHA)",
    )
    parser.add_argument(
        "--files",
        nargs="*",
        default=None,
        help="Classify this file list instead of a git range",
    )
    parser.add_argument(
        "--github-output",
        action="store_true",
        help="Append flags to $GITHUB_OUTPUT",
    )
    parser.add_argument(
        "--step-summary",
        action="store_true",
        help="Append the scope report to $GITHUB_STEP_SUMMARY",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Do not print the scope report to stdout",
    )
    parser.add_argument(
        "--verify-refs",
        action="store_true",
        help="Verify captured promotion SHAs still match remote refs",
    )
    parser.add_argument(
        "--expected-base",
        help="Captured promotion_base_sha (origin/main at scope detection)",
    )
    parser.add_argument(
        "--expected-target",
        help="Captured promotion_target_sha (beta HEAD at scope detection)",
    )
    parser.add_argument(
        "--current-base",
        default="origin/main",
        help="Live base ref to compare (default: origin/main)",
    )
    parser.add_argument(
        "--current-target",
        default="origin/beta",
        help="Live target ref to compare (default: origin/beta)",
    )
    parser.add_argument(
        "--mode",
        choices=("merge", "fast-forward"),
        default="merge",
        help="merge requires both refs unchanged; fast-forward allows main to move",
    )
    parser.add_argument(
        "--fast-forward-to",
        help="Destination commit beta should fast-forward to (usually origin/main)",
    )
    parser.add_argument(
        "--decide-merge",
        action="store_true",
        help="Decide whether the captured target still needs a merge into main",
    )
    parser.add_argument(
        "--validate-versions",
        action="store_true",
        help="Validate TOC versions for the captured base/target promotion case",
    )
    return parser


def main(argv=None):
    """Classify a git range or explicit file list."""
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.verify_refs:
        if not args.expected_base or not args.expected_target:
            parser.error("--verify-refs requires --expected-base and --expected-target")
        errors = verify_promotion_refs(
            args.expected_base,
            args.expected_target,
            args.current_base,
            args.current_target,
            mode=args.mode,
            destination=args.fast_forward_to,
        )
        if errors:
            for error in errors:
                print(f"::error::{error}", file=sys.stderr)
                print(error)
            return 1
        if args.mode == "fast-forward":
            print(
                "Captured promotion target is unchanged and is an ancestor of "
                "the fast-forward destination."
            )
        else:
            print("Captured promotion refs still match origin/main and origin/beta.")
        return 0

    if args.decide_merge:
        if not args.expected_target:
            parser.error("--decide-merge requires --expected-target")
        plan = plan_promotion_git_mutation(args.expected_target, args.current_base)
        if args.github_output:
            output_path = os.environ.get("GITHUB_OUTPUT")
            if not output_path:
                print("::error::GITHUB_OUTPUT is not set", file=sys.stderr)
                return 1
            with Path(output_path).open("a", encoding="utf-8") as handle:
                handle.write(f"merge_required={bool_text(plan['merge_required'])}\n")
                handle.write(
                    "target_contained_in_main="
                    f"{bool_text(plan['target_contained_in_main'])}\n"
                )
        if plan["merge_required"]:
            print(
                "Captured promotion target is not contained in main. "
                "Merge commit required."
            )
        else:
            print(
                "Captured promotion target is already contained in main. "
                "No merge commit required."
            )
        return 0

    if args.validate_versions:
        if not args.expected_base or not args.expected_target:
            parser.error(
                "--validate-versions requires --expected-base and --expected-target"
            )
        scope = classify_git_range(args.expected_base, args.expected_target)
        errors = validate_promotion_toc_versions(
            scope.release_required,
            bool(scope.merge_required),
            args.expected_target,
            args.expected_base,
        )
        authoritative = (
            args.expected_target if (scope.release_required or scope.merge_required) else args.expected_base
        )
        print(
            "TOC version validation: "
            f"release_required={bool_text(scope.release_required)} "
            f"merge_required={bool_text(scope.merge_required)}"
        )
        try:
            print(f"Authoritative commit: {resolve_commit(authoritative)}")
            print(f"Version: {read_toc_version_from_ref(authoritative)}")
        except RuntimeError as exc:
            message = str(exc)
            if message not in errors:
                errors.append(message)
        if errors:
            for error in errors:
                print(f"::error::{error}", file=sys.stderr)
                print(error)
            return 1
        print("TOC version validation passed.")
        return 0

    if args.files is not None and (args.base or args.head):
        parser.error("Use either --files or --base/--head, not both")
    if args.files is None and not (args.base and args.head):
        parser.error("Provide --base and --head, or --files")

    if args.files is not None:
        scope = classify_files(args.files)
    else:
        scope = classify_git_range(args.base, args.head)

    report = format_scope_report(scope)
    if not args.quiet:
        print(report)

    if args.github_output:
        output_path = os.environ.get("GITHUB_OUTPUT")
        if not output_path:
            print("::error::GITHUB_OUTPUT is not set", file=sys.stderr)
            return 1
        write_github_output(scope, output_path)

    if args.step_summary:
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if not summary_path:
            print("::error::GITHUB_STEP_SUMMARY is not set", file=sys.stderr)
            return 1
        with Path(summary_path).open("a", encoding="utf-8") as handle:
            handle.write("## Promotion Scope\n\n")
            handle.write("```text\n")
            handle.write(report)
            handle.write("```\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
