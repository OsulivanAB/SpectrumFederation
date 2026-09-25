# Automation and Releases

Spectrum Federation uses a beta-first workflow. Normal pull requests target `beta`; `main` is updated by the promotion workflow.

## Pull-request validation

### PRs to beta

`.github/workflows/pr-beta-validation.yml` runs when relevant addon, automation, workflow, or documentation files change. It:

- detects whether packaged addon files changed (via `classify_promotion_scope.py`);
- runs the unified Lua/YAML/Python linter;
- runs focused Python/Lua tests, including `tests/test_promotion_scope.py`, `tests/test_sync_protocol.py`, and `tests/test_linked_identity.py`;
- validates package structure;
- requires a TOC version bump and a non-duplicate beta release only when a packaged addon file changed;
- builds MkDocs in strict mode.

Documentation-only changes do not require an addon version bump. Packaged-addon detection uses `.github/scripts/classify_promotion_scope.py`, so zip-excluded files such as `*/AGENTS.md` do not count as addon changes.

### PRs to main

`.github/workflows/pr-main-validation.yml` runs lint, tests, packaging, stable-version-format, and documentation checks. Direct feature work should not normally target this branch.

`.github/workflows/pr-template-validation.yml` separately validates pull-request template completion. In-game testing must be either marked complete or explicitly marked not applicable. N/A is rejected when packaged addon files changed, or when a TOC change is runtime-affecting, unknown, or not inspectable. Zip-excluded repository files such as `*/AGENTS.md` may still use N/A.

Both branch-validation workflows include `README.md`, `tests/**`, `pkgmeta.yaml`, and MkDocs inputs (`docs/**`, `mkdocs.yml`, `overrides/**`, `requirements-docs.txt`) in their path filters.

## Post-merge beta release

`.github/workflows/post-merge-beta.yml` is triggered by pushes under the packaged addon trees or `pkgmeta.yaml`. Path filters start the workflow; they do not encode individual zip exclusions. The workflow classifies the immutable `github.event.before...github.sha` range with `classify_promotion_scope.py` before any release side effects. Zip-excluded addon-tree files, including `*/AGENTS.md`, do not set `release_required`. A `pkgmeta.yaml` change does, because package validation and WowUp's git packaging path still read that file. CurseForge no longer rebuilds releases from it once automatic packaging is disabled.

When `release_required` is false, changelog, README badge, GitHub Release, Wago, and CurseForge side effects are skipped. Lint/packaging/docs validation and merged-branch cleanup still run; they do not depend on a successful publish. A guidance-only addon-tree push can therefore start the workflow, classify as `release_required=false`, skip every release/version job, and still run sanity checks plus merged-branch cleanup.

When `release_required` is true, the workflow:

1. reruns lint, packaging, and documentation validation;
2. verifies the TOC was bumped against the previous beta tip (`check_version_bump.py --base-commit`) and is not a duplicate release;
3. queries Blizzard's beta product for Interface metadata;
4. updates `CHANGELOG.md`;
5. updates README badges;
6. checks out the captured push SHA, overlays generated `CHANGELOG.md` / `README.md` from live `beta`, refuses to publish if any packaged addon file has advanced, packages the addon zip, writes WowUp `release.json`, creates a GitHub prerelease, and uploads the same zip to Wago as `beta`;
7. deletes the merged source branch after a successful or skipped publish, never after a failed one.

Version extraction, duplicate-release checks, and the publisher all use the captured push SHA rather than live `beta`. `publish_release.py` also refuses to create a zip whose requested version does not match the packaged parent and child TOC versions. Concurrency serializes workflow runs, but it does not freeze the `beta` branch; the captured SHA plus packaged-tree verification is what keeps a later push from being published under an earlier version.

A packaged addon change with a forgotten or invalid version fails the workflow instead of silently skipping the beta release.

Docs-only merges do not trigger a beta addon release.

Parent/child addon membership and zip exclusions live in `.github/scripts/validate_packaging.py`. The validation zip, production zip, and release-scope classifier all consume those definitions. The classifier also treats `pkgmeta.yaml` as release-relevant even though that file is not a zip member.

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

The dry-run promotion job fetches the captured promotion target SHA, uses the incoming `update_changelog.py` from that commit, and analyzes `HEAD...<target SHA>` with the upcoming stable version so the changelog path can be validated without pushing.

### Safeguards

- Historical stable sections are not rewritten.
- Rerunning a job does not replace an existing non-placeholder section for the same version.
- Internal-only changes (CI, tests, docs, TOC metadata) do not create a user-facing entry.
- Reverted beta work that is absent from the net addon diff is omitted from the main entry, including when the remaining files do not match a known feature name. Pull-request titles and commit subjects are filtered the same way so they cannot restore a dropped feature.
- If the model is uncertain and no grounded fallback exists, the script does not invent a stable entry. On promotion it still removes leftover `-beta` sections so `main` does not keep prerelease headings.

Deterministic range, validation, and write-safety behavior is covered by `tests/test_update_changelog.py`.

## Promote beta to main

`.github/workflows/promote-beta-to-main.yml` is manually dispatched with no inputs. Every run performs a complete local dry-run phase first. The actual phase starts automatically only if all required dry-run jobs succeed, including jobs that were skipped because they were not applicable.

Branch promotion and downstream publishing are separate decisions. Every valid dispatch still promotes the captured `beta` SHA into `main` when that SHA is not already contained in `main`, and fast-forwards `beta` onto current `main` when remote `beta` has not advanced. If the captured target is already an ancestor of `main`, the merge is a no-op: `main` is preserved and `beta` can catch up without an empty promotion commit. Changelog generation, README badge work, stable addon publishing, and MkDocs deployment run only when the promotion scope says they are applicable.

### How promotion scope is determined

The first job captures an immutable range and classifies it with `.github/scripts/classify_promotion_scope.py`. Detect still checks out live `beta` so `HEAD` is the captured target, and it copies the helper from that live checkout first so packaged membership matches the tree being classified. If leftover `beta` predates the helper, it falls back to `origin/main`, then the dispatched workflow commit (`github.sha`). Those SHAs are invariants for the rest of the run, not informational outputs:

1. `promotion_base_sha` is `origin/main` at workflow start.
2. `promotion_target_sha` is the `beta` HEAD at workflow start.
3. Changed files are `git diff --name-only` from `merge-base(base, target)` to `target` (`origin/main...beta`). That is the incoming promotion, not later workflow-generated commits.

Before the dry-run merge, the real merge, and the final beta sync, the workflow re-fetches `origin/main` and `origin/beta` and verifies them with `classify_promotion_scope.py --verify-refs`. Merge jobs check out `main`, so they copy that helper from a verified git object. The copy must support `--validate-versions` (and therefore `--decide-merge`): the workflow prefers the captured target SHA and falls back to current `main` when leftover beta predates the flag. Fast-forward jobs likewise copy a helper that supports `--verify-refs`, preferring the dispatched workflow commit, then `origin/main`, then the captured target. Git ancestry, via `--decide-merge`, then decides whether a merge commit is required. `has_incoming_changes` is a changed-file classification and is not used as the merge skip switch. When the captured target is not already contained in `main`, merge and file checkouts use that target SHA, not the live `beta` ref. When it is already contained, the workflow does not manufacture an empty merge commit and does not overlay CHANGELOG/README/TOC files from the older beta target. If either branch has moved unexpectedly, the job fails and tells the maintainer to rerun the promotion so scope and mutation stay aligned.

The script is the source of truth for path classification. Update it when packaged addon roots, zip excludes, `pkgmeta.yaml` release membership, or MkDocs inputs change. It does not use AI.

| Flag | Meaning |
| --- | --- |
| `addon_changed` | A file that ships in the release zip changed, or `pkgmeta.yaml` changed. Addon roots and zip exclusions come from `validate_packaging.py`; `*/AGENTS.md` and `*.git*` are excluded. `pkgmeta.yaml` is not a zip member. Package validation and WowUp's git packaging path still read it. CurseForge direct publishing uploads the canonical zip instead of rebuilding from this file. |
| `docs_changed` | MkDocs sources changed: `docs/**`, `mkdocs.yml`, `overrides/**`, or `requirements-docs.txt`. |
| `readme_changed` | `README.md` is in the incoming diff. |
| `release_required` | Same as `addon_changed`. Incoming packaged addon or `pkgmeta.yaml` changes warrant a stable release. Generated TOC/version commits do not create this flag. |
| `changelog_required` | Same as `release_required`. AI may write the changelog text; it does not decide whether a changelog is needed. |
| `documentation_deploy_required` | Same as `docs_changed`. Docs-only promotions deploy MkDocs and do not publish an addon release. |
| `readme_work_required` | Incoming README change or a stable addon release (badge/version updates). |

These flags are independent. Addon plus documentation is `addon_changed=true` and `docs_changed=true`, which requires both a stable release and MkDocs deployment.

| Incoming changes | Promote branches | Changelog | Addon release | MkDocs deploy | README work |
| --- | --- | --- | --- | --- | --- |
| Addon only | Yes | Yes | Yes | No | Yes |
| Docs only | Yes | No | No | Yes | No |
| Addon + docs | Yes | Yes | Yes | Yes | Yes |
| README only | Yes | No | No | No | Yes |
| Workflow/dev only | Yes | No | No | No | No |
| No downstream-relevant changes | Yes | No | No | No | No |

The workflow:

1. classifies the incoming `main...beta` range and captures the base/target SHAs;
2. validates lint, packaging, docs, and TOC version format. Addon releases require `X.Y.Z-beta.N` on the captured beta target. Non-addon merges require a stable `X.Y.Z` on that target so a prerelease TOC cannot be overlaid onto `main`. When the captured target is already contained in `main`, the captured main SHA is authoritative and must be stable `X.Y.Z`; the leftover beta checkout may still contain `-beta.N`;
3. dry-runs only the applicable merge, changelog, README, docs, release, and fast-forward steps without pushing, using the captured target SHA and the same ref-drift checks as the real merge;
4. re-verifies that `origin/main` and `origin/beta` still match the captured SHAs, then merges the captured target SHA into `main` only when that target is not already contained in `main`;
5. when `release_required`, removes `-beta.N`, fetches the live Interface value, updates the changelog, verifies the `main` checkout still matches the captured packaged source (TOC rewrites allowed), and publishes a stable GitHub Release plus a Wago `stable` upload;
6. when `readme_work_required`, updates README badges;
7. when `documentation_deploy_required`, deploys MkDocs from `main`;
8. re-verifies that `origin/beta` still equals the captured target and that the target is an ancestor of `origin/main`, then fast-forwards `beta` with a non-force `git push origin origin/main:refs/heads/beta`. Newer beta work is never overwritten.

Dry-run and real jobs consume the same scope outputs. The dry-run summary prints the detected flags and which operations would run. The final summary compares detected scope, required operations, and actual job results. If a required operation is skipped or fails, or a non-required operation runs, the summary fails the workflow instead of reporting success.

Older instructions that ask for a promotion `dry_run` input are obsolete; the workflow now always validates with its built-in dry-run phase.

When a dry-run README job runs, it uploads its simulated stable badge output to the dry-run docs job, which applies simulated stable TOC metadata before calling `validate_docs.py`. Docs-only dry runs skip that overlay and validate the incoming documentation as-is. The final `main` deployment also calls the validator after generated metadata is pushed.

## GitHub, CurseForge, and Wago publishing

`.github/scripts/publish_release.py` is the shared publisher for beta and stable addon releases. GitHub Releases remain part of the pipeline. CurseForge and Wago are explicit downstream destinations. Do not replace GitHub Releases with either external publisher.

A live publish does the following:

1. Build the existing release artifacts: the addon zip (parent plus packaged child addons from `validate_packaging.py` at the zip root) and WowUp Hub `release.json`. The publisher refuses to zip when the requested version does not match the packaged TOC versions.
2. Build release notes from `CHANGELOG.md`.
3. Create or update the GitHub Release (prerelease for `-beta`, `-alpha`, and `-rc` versions).
4. After GitHub succeeds, attempt CurseForge and Wago independently. Neither destination waits on the other, and neither deletes a destination that already succeeded.

```text
Build/Validate -> GitHub -> CurseForge
                         -> Wago
```

If GitHub fails before a release exists, CurseForge and Wago are not attempted. If GitHub succeeds and one downstream destination fails, the workflow fails after the other destination has been attempted. The GitHub Release, and any downstream publish that succeeded, stay in place.

WowUp continues to use GitHub `release.json` and the canonical zip. Changelog text is reused for GitHub release notes, the CurseForge changelog, and the Wago changelog. There is no second changelog generator.

### Version mapping

Classification comes from the version string, not from the current git branch:

| Version | GitHub | Wago stability | CurseForge release type |
| --- | --- | --- | --- |
| `1.4.0` | Release | `stable` | `release` |
| `1.5.0-beta.1` | Prerelease | `beta` | `beta` |
| `1.5.0-alpha.1` | Prerelease | `alpha` | `alpha` |
| `1.5.0-rc.1` | Prerelease | `beta` | `beta` |

Matching is case-insensitive (`1.5.0-BETA.2` is a GitHub prerelease, Wago `beta`, and CurseForge `beta`).

### Project IDs and Retail patch

The public Wago project ID is stored as `## X-Wago-ID:` on the parent TOC and on every packaged child TOC. Child addons reuse that same ID; they do not get a second Wago project. WowUp and Wago use the shared ID to install the sibling folders from one listing. The publisher reads the parent TOC field instead of hard-coding the ID in workflows.

The public CurseForge project ID is `## X-Curse-Project-ID:` on the parent TOC only. It is not a secret. Direct publishing reads that field and refuses to upload when it is missing or not a positive integer. The current project ID is `1445757`.

`pkgmeta.yaml` still lifts each shipped addon to the zip root for git packagers and for package validation. A parent-only flatten leaves `SpectrumFederation_CursedSurgeTracker` and `SpectrumFederation_RCLootCouncilIntegration` nested inside `SpectrumFederation/`, which installers never load as optional AddOns. CurseForge direct publishing uploads the canonical zip produced by `publish_release.py`. It does not ask CurseForge to rebuild the addon from `pkgmeta.yaml`. Keep `pkgmeta.yaml`; WowUp's git packaging path and `validate_packaging.py` still depend on it.

The Retail patch sent to Wago and used to select the CurseForge game version is the human-readable form of the 6-digit Interface number already used for releases (`120100` → `12.1.0`).

- Wago requires that exact string in `https://addons.wago.io/api/data/game`. The script does not claim an older patch.
- CurseForge requires that exact Retail name from the documented Game Versions API at `https://wow.curseforge.com/api/game/versions`. The numeric game-version ID is resolved from that catalog and is not hard-coded. Classic, PTR, and other non-Retail version types are ignored. If the exact Retail patch cannot be identified, CurseForge publishing fails. The catalog result is reused for the rest of that release process.

Release notes reuse `CHANGELOG.md`. Beta versions look for `## [X.Y.Z-beta.N]` and then `## [Unreleased - Beta]`. Stable, alpha, and RC versions use exact-heading lookup only; current changelog automation does not create alpha/RC sections, and the publisher does not invent them.

### Credentials

- `WAGO_API_KEY` is the Wago developer API credential. Direct publishing uses only this value, as `Authorization: Bearer …` according to [Wago's API docs](https://docs.wago.io/).
- `WAGO_API_SECRET` is the signing secret from the old Wago GitHub Release webhook. The publisher does not read or send it.
- `CURSEFORGE_API_TOKEN` is the CurseForge author Upload API token. Direct publishing sends it only as the `X-Api-Token` header, per the [CurseForge Upload API](https://support.curseforge.com/support/solutions/articles/9000197321-curseforge-upload-api). It is not placed in the request body or query string.

Never log these secrets, Authorization headers, `X-Api-Token` values, or the legacy CurseForge webhook token. The publisher does not read the legacy webhook token.

### Migration: CurseForge automatic packaging

Wago's old GitHub Release webhook should already be disabled. Leave `WAGO_API_SECRET` unused.

CurseForge automatic packaging may still be enabled when this publisher first ships, so beta releases are not lost before the replacement is in production. Do not disable it before the direct publisher is merged and the repository secret exists. After that, complete this one-time manual migration. Repository code does not change CurseForge account settings or revoke tokens.

1. Confirm `CURSEFORGE_API_TOKEN` exists in repository Actions secrets.
2. Validate the direct publisher with dry-run and `tests/test_publish_release.py`.
3. Merge and deploy the direct publisher.
4. Disable CurseForge repository **Automatic Packaging**.
5. Remove or disable the CurseForge GitHub webhook.
6. Revoke the old CurseForge token labeled `Webhooks` once nothing uses it.
7. Keep `CURSEFORGE_API_TOKEN`.
8. Verify the next beta release on GitHub, CurseForge as Beta, Wago as Beta, and WowUp.

The first release that includes this publisher can race the still-enabled automatic packager. Disable automatic packaging as soon as the direct publisher is deployed. If both paths upload the same version, remove the extra CurseForge file manually. A later rerun treats an exact existing file or an explicit duplicate response as success and does not upload another copy.

### Dry-run

A dry-run must not create a GitHub Release, upload to CurseForge, upload to Wago, or mutate any external release service. It validates the CurseForge project ID, release type, and Retail patch locally, and it may resolve the public Wago catalog before printing the simulated actions. It does not send `CURSEFORGE_API_TOKEN`. The numeric CurseForge game-version ID is resolved during a live publish, when that token is available.

From the repository root, after substituting the version and Interface values you intend to publish:

```bash
python3 .github/scripts/publish_release.py 1.5.0-beta.1 --interface 120100 --dry-run
```

The promotion workflow already runs this with `--dry-run` during its validation phase. Dry-run does not require `WAGO_API_KEY`, `CURSEFORGE_API_TOKEN`, or a GitHub token.

### Retry when one destination fails

- If GitHub fails, CurseForge and Wago are not attempted.
- If GitHub succeeds and CurseForge fails, Wago is still attempted. Keep the GitHub Release and any Wago release that succeeded. Fix the CurseForge error and rerun `publish_release.py` for the same version.
- If GitHub succeeds and Wago fails, CurseForge is still attempted. Keep the GitHub Release and any CurseForge file that succeeded. Fix the Wago error and rerun the same version.
- Do not delete a GitHub Release, CurseForge file, or Wago version because a different destination failed.
- A Wago or CurseForge HTTP 409 is treated as success only when the response body clearly says this exact version or file already exists. An empty or generic 409 is a visible failure.
- Before uploading, the publisher also checks `GET /api/projects/{projectId}/files` on the CurseForge author API for an exact zip name or display name. That list call is not part of the documented Upload API. A missing, forbidden, or otherwise unusable list response is treated as unavailable and does not block the upload. The documented upload endpoint decides authentication. Duplicate safety then falls back to the explicit upload response described above. A generic conflict is still a failure.
- An unexpected error in the CurseForge attempt does not skip Wago, and an unexpected error in the Wago attempt does not discard a CurseForge result that already succeeded.
- If the GitHub Release already exists, the existing update/reuse path is preserved, and CurseForge and Wago are still attempted afterward.

### Tests

Release classification, CurseForge and Wago metadata, credential handling, and mocked HTTP behavior are covered by `tests/test_publish_release.py`.

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
| `publish_release.py` | Build release artifacts, create or update the GitHub Release, then publish the same zip to CurseForge and Wago. |
| `update_changelog.py` | Update the beta changelog after merge, or consolidate the main changelog during promotion. |
| `classify_promotion_scope.py` | Classify a git range or file list into addon/docs/README/infra flags used by promotion and PR addon detection. |
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

Release zips contain sibling top-level folders `SpectrumFederation/`, `SpectrumFederation_CursedSurgeTracker/`, and `SpectrumFederation_RCLootCouncilIntegration/`. Extracting the archive into `Interface/AddOns` installs those addons. Packaged child TOCs must keep the same `## Interface` and `## Version` values as the parent.

README badges are generated release metadata, not the source of truth. The Interface badge is formatted from the 6-digit Interface number (the same `MMmmpp` value stored in the TOC) by adding decimals and stripping leading zeros (`120100` → `12.1.0`).
