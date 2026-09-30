---
applyTo: "SpectrumFederation/**/*,.github/**/*"
---

# TOC Version Policy

Version bumps follow deterministic `release_required` classification in
`.github/scripts/classify_promotion_scope.py`, enforced by
`.github/scripts/check_version_bump.py` when a PR changes packaged addon or
release-packaging paths.

## When a bump is required

Bump `## Version:` in `SpectrumFederation/SpectrumFederation.toc` (and keep
packaged child TOC Version/Interface values in lockstep) when the PR changes
**packaged** addon contents or release packaging metadata, including:

- Lua/XML source that ships in the release zip
- Media or other assets bundled with the addon
- TOC metadata that affects the packaged addon
- `pkgmeta.yaml` when it can change installed layout

Instruction-only, docs-only, workflow/script, and other infra changes —
including zip-excluded files such as `*/AGENTS.md` — do **not** require a
version bump when the current TOC version is already valid for the target
branch. A repair iteration does not automatically require another increment
when the PR version is already valid and ahead of the base for delivery.

Even when no bump is required, verify that the TOC version format is valid for
the branch you are targeting, and correct it if it is not.

## How to bump

1. Open `SpectrumFederation/SpectrumFederation.toc` and find the `## Version:` line.
2. Increment the version according to the branch you are on:
   - **beta branch** → keep the `-beta.N` suffix, increment N by 1.
     - Example: `0.5.0-beta.3` → `0.5.0-beta.4`
     - ⚠️ A version **without** `-beta.N` (e.g., `0.5.0`) is **never** valid on the beta branch.
   - **main branch** → bump SemVer (patch for bug fixes, minor for new features, major for breaking changes) and drop the `-beta.N` suffix.
     - Example (patch): `0.5.0-beta.4` → `0.5.1`
     - Example (minor): `0.5.0-beta.4` → `0.6.0`
3. Commit the TOC change alongside your other changes when a bump is required.

## Do this early when required

When `release_required` applies, read the current `## Version:` line at the
start of the task so you know what to increment. Omitting a required bump is a
PR blocker. Full packaging policy: root `AGENTS.md`.
