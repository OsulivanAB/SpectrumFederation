# Automation and Releases

Spectrum Federation uses a beta-first workflow. Normal pull requests target `beta`; `main` is updated by the promotion workflow.

## Pull-request validation

### PRs to beta

`.github/workflows/pr-beta-validation.yml` runs when relevant addon, automation, workflow, or documentation files change. It:

- detects whether packaged addon files changed (via `classify_promotion_scope.py`);
- runs the unified Lua/YAML/Python linter;
- runs focused Python/Lua tests, including `tests/test_promotion_scope.py`;
- validates package structure;
- requires a TOC version bump and a non-duplicate beta release only for addon changes;
- builds MkDocs in strict mode.

Documentation-only changes do not require an addon version bump. Packaged-addon detection uses `.github/scripts/classify_promotion_scope.py`, so zip-excluded files such as `*/AGENTS.md` do not count as addon changes.

### PRs to main

`.github/workflows/pr-main-validation.yml` runs lint, tests, packaging, stable-version-format, and documentation checks. Direct feature work should not normally target this branch.

`.github/workflows/pr-template-validation.yml` separately validates pull-request template completion. In-game testing must be either marked complete or explicitly marked not applicable. N/A is rejected when packaged addon files changed, or when a TOC change is runtime-affecting, unknown, or not inspectable. Zip-excluded repository files such as `*/AGENTS.md` may still use N/A.

Both branch-validation workflows include `README.md`, `tests/**`, and MkDocs inputs (`docs/**`, `mkdocs.yml`, `overrides/**`, `requirements-docs.txt`) in their path filters.

## Post-merge beta release

`.github/workflows/post-merge-beta.yml` runs only when a push to `beta` changes packaged addon files under `SpectrumFederation/**`, `SpectrumFederation_CursedSurgeTracker/**`, or `SpectrumFederation_RCLootCouncilIntegration/**`. Zip-excluded files such as `*/AGENTS.md` do not start a beta release.

It:

1. reruns lint, packaging, and documentation validation;
2. queries Blizzard's beta product for Interface metadata;
3. updates `CHANGELOG.md`;
4. updates README badges;
5. packages the addon zip, writes WowUp `release.json`, creates a GitHub prerelease, and uploads the same zip to Wago as `beta`;
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

The first job captures an immutable range and classifies it with `.github/scripts/classify_promotion_scope.py`. Those SHAs are invariants for the rest of the run, not informational outputs:

1. `promotion_base_sha` is `origin/main` at workflow start.
2. `promotion_target_sha` is the `beta` HEAD at workflow start.
3. Changed files are `git diff --name-only` from `merge-base(base, target)` to `target` (`origin/main...beta`). That is the incoming promotion, not later workflow-generated commits.

Before the dry-run merge, the real merge, and the final beta sync, the workflow re-fetches `origin/main` and `origin/beta` and verifies them with `classify_promotion_scope.py --verify-refs`. Merge jobs check out `main`, so they copy that helper from a verified git object. The copy must support `--validate-versions` (and therefore `--decide-merge`): the workflow prefers the captured target SHA and falls back to current `main` when leftover beta predates the flag. Git ancestry, via `--decide-merge`, then decides whether a merge commit is required. `has_incoming_changes` is a changed-file classification and is not used as the merge skip switch. When the captured target is not already contained in `main`, merge and file checkouts use that target SHA, not the live `beta` ref. When it is already contained, the workflow does not manufacture an empty merge commit and does not overlay CHANGELOG/README/TOC files from the older beta target. If either branch has moved unexpectedly, the job fails and tells the maintainer to rerun the promotion so scope and mutation stay aligned.

The script is the source of truth for path classification. Update it when packaged addon roots, zip excludes, or MkDocs inputs change. It does not use AI.

| Flag | Meaning |
| --- | --- |
| `addon_changed` | A file that ships in the release zip changed. Addon roots come from packaging; `*/AGENTS.md` and `*.git*` are excluded. |
| `docs_changed` | MkDocs sources changed: `docs/**`, `mkdocs.yml`, `overrides/**`, or `requirements-docs.txt`. |
| `readme_changed` | `README.md` is in the incoming diff. |
| `release_required` | Same as `addon_changed`. Incoming packaged addon changes warrant a stable release. Generated TOC/version commits do not create this flag. |
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
5. when `release_required`, removes `-beta.N`, fetches the live Interface value, updates the changelog, and publishes a stable GitHub Release plus a Wago `stable` upload;
6. when `readme_work_required`, updates README badges;
7. when `documentation_deploy_required`, deploys MkDocs from `main`;
8. re-verifies that `origin/beta` still equals the captured target and that the target is an ancestor of `origin/main`, then fast-forwards `beta` with a non-force `git push origin origin/main:refs/heads/beta`. Newer beta work is never overwritten.

Dry-run and real jobs consume the same scope outputs. The dry-run summary prints the detected flags and which operations would run. The final summary compares detected scope, required operations, and actual job results. If a required operation is skipped or fails, or a non-required operation runs, the summary fails the workflow instead of reporting success.

Older instructions that ask for a promotion `dry_run` input are obsolete; the workflow now always validates with its built-in dry-run phase.

When a dry-run README job runs, it uploads its simulated stable badge output to the dry-run docs job, which applies simulated stable TOC metadata before calling `validate_docs.py`. Docs-only dry runs skip that overlay and validate the incoming documentation as-is. The final `main` deployment also calls the validator after generated metadata is pushed.

## GitHub, CurseForge, and Wago publishing

`.github/scripts/publish_release.py` is the shared publisher for beta and stable addon releases. GitHub Releases remain part of the pipeline. Do not replace them with Wago-only publishing.

A live publish does the following, in order:

1. Build the existing release artifacts: the addon zip (`SpectrumFederation/` and `SpectrumFederation_CursedSurgeTracker/` at the zip root) and WowUp Hub `release.json`.
2. Build release notes from `CHANGELOG.md`.
3. Create or update the GitHub Release (prerelease for `-beta`, `-alpha`, and `-rc` versions).
4. After GitHub succeeds, load Wago's catalog, require an exact Retail patch match, and validate Wago project metadata.
5. Upload the same addon zip to Wago Addons with an explicit stability value.

Wago catalog, metadata, authentication, and upload failures happen after the GitHub Release exists. They fail the workflow visibly and do not delete the GitHub Release or roll back CurseForge. Dry-run may resolve and validate Wago before printing the simulated GitHub and Wago actions because dry-run performs no external mutations.

GitHub Release events still fire. CurseForge continues to receive releases through its existing GitHub Release webhook. WowUp continues to use `release.json`. Changelog text is reused for both GitHub release notes and the Wago changelog; there is no second changelog generator.

### Version mapping

Classification comes from the version string, not from the current git branch:

| Version | GitHub | Wago stability |
| --- | --- | --- |
| `1.4.0` | Release | `stable` |
| `1.5.0-beta.1` | Prerelease | `beta` |
| `1.5.0-alpha.1` | Prerelease | `alpha` |
| `1.5.0-rc.1` | Prerelease | `beta` |

Matching is case-insensitive (`1.5.0-BETA.2` is still a GitHub prerelease and Wago `beta`).

### Wago project ID and Retail patch

The public Wago project ID is stored once, as `## X-Wago-ID:` in `SpectrumFederation/SpectrumFederation.toc`. Packaged child addons ship in the same zip and do not get a second Wago ID. The publisher reads that TOC field instead of hard-coding the ID in workflows.

The Wago `supported_retail_patch` value is the human-readable form of the 6-digit Interface number already used for releases (`120100` → `12.1.0`). The script requires that exact string to appear in Wago's public catalog at `https://addons.wago.io/api/data/game`. If the catalog cannot be loaded, or Wago does not advertise that patch yet, publishing fails instead of claiming an older patch. On a live run that failure happens after GitHub has already published, so CurseForge still receives the Release event.

Release notes reuse `CHANGELOG.md`. Beta versions look for `## [X.Y.Z-beta.N]` and then `## [Unreleased - Beta]`. Stable, alpha, and RC versions use exact-heading lookup only; current changelog automation does not create alpha/RC sections, and the publisher does not invent them.

### Credentials

There are two Wago-related GitHub repository secrets with different purposes:

- `WAGO_API_KEY` is the Wago developer API credential. Direct publishing uses only this value, as `Authorization: Bearer …` according to [Wago's API docs](https://docs.wago.io/).
- `WAGO_API_SECRET` is the signing secret from the old GitHub Release webhook. The new publisher does not read or send it.

Never log either secret, Authorization headers, or tokens.

### Migration: disable only the old Wago webhook

Historically Wago imported GitHub Release events through a repository webhook. That import classified beta GitHub prereleases as Wago Stable.

**Disable/remove ONLY the old Wago GitHub Release webhook before enabling direct Wago publishing in production.**

**DO NOT disable the CurseForge Release webhook.**

Leave every other GitHub Release consumer untouched. After the Wago webhook is removed, `WAGO_API_SECRET` may remain in repository Secrets; the new code does not use it.

### Dry-run

A dry-run must not create a GitHub Release, upload to Wago, or mutate any external release service. It may resolve the Wago catalog and validate project metadata before printing the simulated GitHub and Wago actions. It still prints version, GitHub prerelease classification, Wago stability, Wago project ID, supported Retail patch, artifact filename, and the Wago `POST` endpoint.

From the repository root, after substituting the version and Interface values you intend to publish:

```bash
python3 .github/scripts/publish_release.py 1.5.0-beta.1 --interface 120100 --dry-run
```

The promotion workflow already runs this with `--dry-run` during its validation phase. Dry-run does not require `WAGO_API_KEY` or a GitHub token.

### Retry when one destination fails

- If GitHub succeeds and Wago fails, CurseForge may already have the GitHub Release. Do not delete that GitHub Release and do not roll back CurseForge. Fix the Wago error and rerun `publish_release.py` for the same version. The GitHub side updates the existing release; Wago is retried independently.
- A Wago HTTP 409 is treated as success only when the response body clearly says this exact version or label already exists. An empty or generic 409 is a visible failure, not an automatic retry success.
- If the GitHub Release already exists, the existing update/reuse path is preserved, and Wago publishing still runs afterward.

### Tests

Release classification, Wago metadata, credential handling, and mocked HTTP behavior are covered by `tests/test_publish_release.py`.

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
| `publish_release.py` | Build release artifacts, create or update the GitHub Release, and publish the same zip to Wago. |
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
