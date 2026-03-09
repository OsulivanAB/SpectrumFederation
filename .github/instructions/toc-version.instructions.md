---
applyTo: "SpectrumFederation/**/*,.github/**/*"
---

# TOC Version Bump — Required on Every Change

**Any change to files under `SpectrumFederation/` MUST be accompanied by a version bump in `SpectrumFederation/SpectrumFederation.toc`.**

**Even if your PR only touches `.github/` files** (e.g. workflows, scripts, instruction files), you must still verify that the TOC version is valid for the current branch — and fix it if it is not.

## How to bump

1. Open `SpectrumFederation/SpectrumFederation.toc` and find the `## Version:` line.
2. Increment the version according to the branch you are on:
   - **beta branch** → keep the `-beta.N` suffix, increment N by 1.
     - Example: `0.5.0-beta.3` → `0.5.0-beta.4`
     - ⚠️ A version **without** `-beta.N` (e.g., `0.5.0`) is **never** valid on the beta branch.
   - **main branch** → bump SemVer (patch for bug fixes, minor for new features, major for breaking changes) and drop the `-beta.N` suffix.
     - Example (patch): `0.5.0-beta.4` → `0.5.1`
     - Example (minor): `0.5.0-beta.4` → `0.6.0`
3. Commit the TOC change alongside your other changes.

## When is this required?

This applies whenever you modify **any** file inside `SpectrumFederation/`, including:
- Lua source files (`.lua`)
- The TOC file itself (adding new files, changing metadata)
- Media or other assets bundled with the addon

Additionally, even for PRs that **only** change `.github/` files (workflows, scripts, instruction files, etc.), you must **verify** that the TOC version format is valid for the branch you are on (see rules above), and correct it if not.

## Do this early

Read the current `## Version:` line at the **start** of every task so you know what to increment.  
Omitting the version bump is a **PR blocker** — do not submit without it.
