# Automation and Releases

Spectrum Federation uses a beta-first workflow. Normal pull requests target `beta`; `main` is updated by the promotion workflow.

## Pull-request validation

### PRs to beta

`.github/workflows/pr-beta-validation.yml` runs when relevant addon, automation, workflow, or documentation files change. It:

- detects whether packaged addon files changed;
- runs the unified Lua/YAML/Python linter;
- runs `tests/test_settings_navigation.py`, `tests/test_cursed_surge_tracker.py`, `tests/test_mouse_tracer.py`, `tests/test_interface_badge.py`, and `tests/test_loot_helper_window.py` (installs `lua5.1`);
- validates package structure;
- requires a TOC version bump and a non-duplicate beta release only for addon changes;
- builds MkDocs in strict mode.

Documentation-only changes do not require an addon version bump.

### PRs to main

`.github/workflows/pr-main-validation.yml` runs lint, tests, packaging, stable-version-format, and documentation checks. Direct feature work should not normally target this branch.

`.github/workflows/pr-template-validation.yml` separately validates pull-request template completion.

Both branch-validation workflows include `README.md` and `tests/**` in their path filters so documentation and test-only changes still run the matching checks.

## Post-merge beta release

`.github/workflows/post-merge-beta.yml` runs only when a push to `beta` changes `SpectrumFederation/**` or `SpectrumFederation_CursedSurgeTracker/**`.

It:

1. reruns lint, packaging, and documentation validation;
2. queries Blizzard's beta product for Interface metadata;
3. updates `CHANGELOG.md`;
4. updates README badges;
5. packages and publishes a beta release;
6. deletes the merged source branch when the release succeeds.

Docs-only merges do not trigger a beta addon release.

## Changelog automation

Beta and main changelog updates share `.github/scripts/update_changelog.py`. The workflows stay separate; only the generation logic is shared.

### What updates each changelog

- **Beta:** `.github/workflows/post-merge-beta.yml` runs the script after an addon change is pushed to `beta`. The new `## [X.Y.Z-beta.N]` section describes that incremental development update.
- **Main:** `.github/workflows/promote-beta-to-main.yml` runs the same script after beta is merged to `main` and the TOC version is stripped to `X.Y.Z`. That section describes the net user-facing result since the previous main release.

### Deterministic vs AI work

The script determines the following without a model:

- whether this is a beta update or a promotion
- the git range to analyze
- changed addon files, commits, and pull-request metadata
- which existing changelog sections belong to the current release train
- whether the current version section already exists
- whether output is valid enough to write

AI is used only for semantic judgment: whether a change is user-facing, how related beta work should be grouped, and the wording of entries. The model must return JSON. Entries are rejected when they are ungrounded, low-confidence, placeholders, or malformed.

GitHub Models is retired. The script uses Copilot CLI when it is installed, or an optional OpenAI-compatible endpoint from `CHANGELOG_AI_BASE_URL` / `CHANGELOG_AI_API_KEY`. If no model is available, it falls back to pull-request titles and beta notes that can be grounded in the net file list. It does not write the old "Infrastructure and tooling updates" placeholder.

### Promotion range

For Promote Beta to Main, the range is the previous stable `vX.Y.Z` tag (or the first parent of the previous promotion merge) through the commit being promoted. Beta changelog sections for the same `X.Y.Z` train are inputs to consolidate; they are not copied one-for-one onto `main`.

The dry-run promotion job fetches `origin/beta`, uses the incoming `update_changelog.py` from beta, and analyzes `HEAD...origin/beta` with the upcoming stable version so the changelog path can be validated without pushing.

### Safeguards

- Historical stable sections are not rewritten.
- Rerunning a job does not replace an existing non-placeholder section for the same version.
- Internal-only changes (CI, tests, docs, TOC metadata) do not create a user-facing entry.
- Reverted beta work that is absent from the net addon diff is omitted from the main entry, including when the remaining files do not match a known feature name. Pull-request titles and commit subjects are filtered the same way so they cannot restore a dropped feature.
- If the model is uncertain and no grounded fallback exists, the script does not invent a stable entry. On promotion it still removes leftover `-beta` sections so `main` does not keep prerelease headings.

Deterministic range, validation, and write-safety behavior is covered by `tests/test_update_changelog.py`.

## Promote beta to main

`.github/workflows/promote-beta-to-main.yml` is manually dispatched with no inputs. Every run performs a complete local dry-run phase first. The actual phase starts automatically only if all required dry-run jobs succeed.

The workflow:

1. determines whether `SpectrumFederation/**` or `SpectrumFederation_CursedSurgeTracker/**` differs between `main` and `beta`;
2. validates lint, packaging, docs, and the appropriate version format;
3. simulates the merge, metadata changes, docs build, release packaging, and beta synchronization without pushing;
4. merges `beta` into `main`;
5. for addon changes, removes `-beta.N`, fetches the live Interface value, updates the changelog, and publishes a stable release;
6. updates README badges;
7. deploys MkDocs from `main`;
8. force-with-lease synchronizes `beta` to `main`.

If there are no addon changes, the promotion preserves the stable version and skips stable release creation while still promoting and deploying non-addon changes.

Older instructions that ask for a promotion `dry_run` input are obsolete; the workflow now always validates with its built-in dry-run phase.

The dry-run README job uploads its simulated stable badge output to the dry-run docs job, which applies the simulated stable TOC metadata before calling `validate_docs.py`. The final `main` deployment also calls the validator after generated metadata is pushed.

## Roll back a release

`.github/workflows/rollback-release.yml` accepts:

- `release_tag`, such as `v1.0.0`;
- `dry_run`, which defaults to `true`.

It supports releases created by beta-to-main promotion. In live mode it identifies and reverts the promotion merge, deletes the GitHub release and tag, and restores the pre-promotion changelog.

Run and review the default dry run before setting `dry_run` to false.

## Interface synchronization

`.github/scripts/blizzard_api.py` queries Blizzard's public version endpoint for current metadata and formats the README Interface badge from that 6-digit Interface number (`120100` → `12.1.0`). `.github/scripts/wow_interface_sync.py` updates interface metadata through its own workflow/script integration and has focused parser tests in `tests/test_wow_interface_sync.py`.

When changing parser behavior, run:

```bash
python -m pytest tests/test_wow_interface_sync.py
```

When changing Interface badge formatting, run:

```bash
python -m pytest tests/test_interface_badge.py
```

## Validation scripts

| Script | Purpose |
| --- | --- |
| `lint_all.py` | Lua, YAML, and Python validation. |
| `validate_packaging.py` | TOC references, required files, and package structure. |
| `validate_docs.py` | Repository-specific documentation guardrails plus `mkdocs build --clean --strict`. |
| `check_version_bump.py` | Compare TOC versions against a base branch. |
| `check_duplicate_release.py` | Reject an existing release version. |
| `publish_release.py` | Build release artifacts and publish or dry-run them. |
| `update_changelog.py` | Update the beta changelog after merge, or consolidate the main changelog during promotion. |
| `cleanup_merged_branch.py` | Remove the merged source branch after beta release. |

Use the scripts rather than reproducing their logic in ad hoc commands.

### Documentation guardrails

`validate_docs.py` fails before the MkDocs build when it finds:

- a Markdown page missing from navigation or a navigation target missing on disk;
- a broken relative link or image;
- known stale commands, APIs, module paths, workflow names, or Blizzard Settings instructions;
- a referenced workflow, script, or asset that does not exist;
- missing automation-compatible README badges, or stable-branch badge values that disagree with `SpectrumFederation.toc` (the Interface badge uses the human-readable form, so `120100` is shown as `12.1.0`);
- a registered `/sf` command or sync diagnostic alias missing from the command reference;
- a visible unimplemented settings action whose limitation is no longer documented.

When behavior changes intentionally, update the implementation and its documentation together. Remove or revise a stale-pattern rule only when the old form has genuinely become valid again.

## Version and manifest source of truth

Release zips contain sibling top-level folders `SpectrumFederation/` and `SpectrumFederation_CursedSurgeTracker/`. Extracting the archive into `Interface/AddOns` installs both addons. The child TOC must keep the same `## Interface` and `## Version` values as the parent.

README badges are generated release metadata, not the source of truth. The Interface badge is formatted from the 6-digit Interface number (the same `MMmmpp` value stored in the TOC) by adding decimals and stripping leading zeros (`120100` → `12.1.0`).
