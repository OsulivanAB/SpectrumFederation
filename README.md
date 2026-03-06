
![Addon Banner](./assets/readme/SpectrumFederation.jpg)

<!-- STATUS_BADGES_START -->
![WoW Version](https://img.shields.io/badge/WoW-12.0.0-00aaff)
![Track](https://img.shields.io/badge/Track-Retail-ff8800)
![Addon Version](https://img.shields.io/badge/Version-0.5.10-brightgreen)
<!-- STATUS_BADGES_END -->



World of Warcraft addon for the Spectrum Federation guild on Garona.

---

## 📚 Documentation

For detailed information about our guild, addon features, and guides, visit our documentation site:

**[View Full Documentation →](https://osulivanab.github.io/SpectrumFederation/)**

---

## Automation: Interface Sync & Packaging

- Workflow: `.github/workflows/wow-interface-sync.yml` runs every 30 minutes (or manually via **workflow_dispatch**) to align `SpectrumFederation/SpectrumFederation.toc`.
- Live interface resolver strategy order:
  1. Patch server (`https://{region}.patch.battle.net:1119/wow/versions`) with exponential backoff + jitter retries.
  2. Wowhead fallback scrape over HTTPS/443 if port `1119` is blocked or flaky.
  3. Manual override via `LIVE_INTERFACE_OVERRIDE` (validated six-digit interface value), which bypasses network lookups.
- Endpoint mapping: when patch strategy succeeds, it parses the Blizzard `versions` payload and converts `Major.Minor.Patch` into the WoW Interface number `MajorMinorPatch` (e.g., `12.0.1.x` → `120001`).
- Version rules: supports semver (`X.Y.Z` or `X.Y.Z-beta.N`) and integer build numbers; main always gets a patch (+1) bump, and beta keeps its lead by applying the pre-update offset to the new main version. If beta ends up equal to main, beta packaging is skipped.
- Target fields: `## Interface` and `## Version` in `SpectrumFederation/SpectrumFederation.toc` are the authoritative sources the workflow edits.
- Packaging: when a branch is updated, it runs `python3 .github/scripts/publish_release.py <version> --interface <interface> --dry-run` inside that branch to produce zip + `release.json` artifacts; beta artifacts are uploaded only when beta stays ahead of main.
- Secrets required: `BLIZZARD_API_ID`, `BLIZZARD_API_SECRET`, and `PAT` (used for checkouts/pushes through branch protection and passed as `GITHUB_TOKEN` to packaging).
- Local resolver smoke test:
  - `LIVE_INTERFACE_OVERRIDE=120001 python .github/scripts/wow_interface_sync.py --dry-run --region us`
  - This runs the resolver without committing changes and is the recommended fallback when network access (especially port `1119`) is unavailable.

---

## Installation

### WowUp Installation

1. Open WowUp and go to **Get Addons**
2. Click the **Install from URL** button
3. Enter the following URL:
   ```
   https://github.com/OsulivanAB/SpectrumFederation
   ```
4. Click **Install**

### CurseForge Installation

We are not currently available on CurseForge. Please use the WowUp or Manual installation methods instead.

### Manual Installation

1. Download the latest release from the [Releases page](https://github.com/OsulivanAB/SpectrumFederation/releases)
2. Extract the downloaded ZIP file
3. Copy the `SpectrumFederation` folder to your World of Warcraft AddOns directory:
   - **Windows**: `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\`
   - **macOS**: `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
4. Restart World of Warcraft or type `/reload` in-game
