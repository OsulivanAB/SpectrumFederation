
![Addon Banner](./assets/readme/SpectrumFederation.jpg)

<!-- STATUS_BADGES_START -->
![WoW Version](https://img.shields.io/badge/WoW-12.0.0-00aaff)
![Track](https://img.shields.io/badge/Track-Beta-ff8800)
![Addon Version](https://img.shields.io/badge/Version-0.5.15--beta.1-brightgreen)
<!-- STATUS_BADGES_END -->



World of Warcraft addon for the Spectrum Federation guild on Garona.

---

## 📚 Documentation

For detailed information about our guild, addon features, and guides, visit our documentation site:

**[View Full Documentation →](https://osulivanab.github.io/SpectrumFederation/)**

### SpellBook Ping Macros

- Open the SpellBook and switch to the **General** tab to find the addon-owned **Ping Macros** panel just below the spell search box.
- Each button creates or updates one macro for a Blizzard ping type, using `/ping 1` through `/ping 5` so the ping lands at your cursor location when you use the macro.
- If your cursor is free when you click a button, the refreshed macro is picked up immediately so you can drag it onto an action bar.
- The SpellBook panel uses Blizzard ping atlas icons, but the created macros fall back to the default question-mark macro icon because macro APIs do not consume atlas names directly.

---

## Automation: Interface Sync & Packaging

- Workflow: `.github/workflows/wow-interface-sync.yml` runs every 30 minutes (or manually via **workflow_dispatch**) to align `SpectrumFederation/SpectrumFederation.toc`.
- Live interface resolver strategy order:
  1. Patch server (`https://{region}.patch.battle.net:1119/wow/versions`) with exponential backoff + jitter retries.
  2. HTTPS fallback over `443`, first `https://blizztrack.com/view/wow?type=versions`, then `https://www.blizzmeta.com/view/wow?type=versions`.
  3. Manual override via `LIVE_INTERFACE_OVERRIDE` (validated six-digit interface value), used as the final fallback.
- Endpoint mapping: when patch strategy succeeds, it parses the Blizzard `versions` payload and converts `Major.Minor.Patch` into the WoW Interface number `MajorMinorPatch` (e.g., `12.0.1.x` → `120001`).
- Version rules: supports semver (`X.Y.Z` or `X.Y.Z-beta.N`) and integer build numbers; main always gets a patch (+1) bump, and beta keeps its lead by applying the pre-update offset to the new main version. If beta ends up equal to main, beta packaging is skipped.
- Target fields: `## Interface` and `## Version` in `SpectrumFederation/SpectrumFederation.toc` are the authoritative sources the workflow edits.
- Branch mutation ownership: `wow_interface_sync.py` now plans/applies TOC updates and emits outputs; commit/push steps are performed explicitly in the workflow.
- Packaging: when a branch is updated, it runs `python3 .github/scripts/publish_release.py <version> --interface <interface> --dry-run` inside that branch to produce zip + `release.json` artifacts; beta artifacts are uploaded only when beta stays ahead of main.
- Promotion separation: `wow-interface-sync` does not invoke `promote-beta-to-main`; release promotion remains isolated in its own workflow.
- Secrets required: `BLIZZARD_API_ID`, `BLIZZARD_API_SECRET`, and `PAT` (used for checkouts/pushes through branch protection and passed as `GITHUB_TOKEN` to packaging).
- Local resolver smoke tests:
  - No-network deterministic check: `LIVE_INTERFACE_OVERRIDE=120001 python .github/scripts/wow_interface_sync.py --dry-run --region us --no-network`
  - Normal dry-run (tries network first): `python .github/scripts/wow_interface_sync.py --dry-run --region us --main-path "$PWD" --beta-path "$PWD"`
  - If port `1119` is blocked/flaky, use `LIVE_INTERFACE_OVERRIDE` or `--no-network` for deterministic local validation.

---

## Installation

### WowUp Installation

- Open WowUp, go to **Get Addons**, search for "Spectrum Federation", and install directly.
- Alternatively, use the Install from URL option and paste:
  ```
  https://github.com/OsulivanAB/SpectrumFederation
  ```

### CurseForge Installation

- Spectrum Federation is available on CurseForge — search for "Spectrum Federation" in the CurseForge client or visit:
  https://www.curseforge.com/wow/addons/spectrum-federation
- Use the CurseForge client or the website to download/install the addon.

### Manual Installation

1. Download the latest release from the [Releases page](https://github.com/OsulivanAB/SpectrumFederation/releases)
2. Extract the downloaded ZIP file
3. Copy the SpectrumFederation folder to your World of Warcraft AddOns directory:
  - **Windows**: C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\
  - **macOS**: /Applications/World of Warcraft/_retail_/Interface/AddOns/
4. Restart World of Warcraft or type `/reload` in-game
