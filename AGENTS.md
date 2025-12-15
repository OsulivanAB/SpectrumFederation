# AI Agent Guidelines for SpectrumFederation

This document provides guidance for AI coding assistants (GitHub Copilot, Cursor, Claude, etc.) working with the SpectrumFederation World of Warcraft addon.

## Project Overview

SpectrumFederation is a **World of Warcraft addon** written in **Lua 5.1** for the Spectrum Federation guild on Garona. It targets both Retail and Beta/PTR versions of WoW.

## Code Structure

### Addon Code Location
- **All in-game addon code lives under `SpectrumFederation/`**
- Never place Lua files outside this directory
- The `SpectrumFederation.toc` file is the manifest that controls load order

### Directory Organization
```
SpectrumFederation/
├── SpectrumFederation.lua    # Main entry point
├── SpectrumFederation.toc    # Addon manifest (CRITICAL)
├── modules/                  # Feature modules
│   ├── core.lua
│   └── ui.lua
└── locale/                   # Localization
    └── enUS.lua
```

### Files to NEVER Edit Directly
- `.github/workflows/release.yml` - Never modify to move tags
- `BlizzardUI/` - Generated locally, git-ignored
- Any files in `.devcontainer/` unless specifically requested

## Lua Environment

### Language Specifics
- **Use Lua 5.1 dialect** (not 5.2, 5.3, or 5.4)
- This is WoW's embedded Lua version with specific limitations:
  - No `goto` statement
  - No bitwise operators (use `bit` library)
  - Limited standard library
  - No `io` or `os` libraries (sandboxed)

### WoW-Specific Globals
- Use WoW API functions (e.g., `CreateFrame`, `UnitName`, `GetRealmName`)
- Reference Blizzard UI globals when needed (e.g., `UIParent`, `GameFontNormal`)
- Check `BlizzardUI/live/` or `BlizzardUI/beta/` for API references (generated in dev container)
- Use `SLASH_COMMANDS` for slash command registration
- Frame events use `RegisterEvent` / `UnregisterEvent`

### Code Style
- Follow existing patterns in `modules/core.lua` and `modules/ui.lua`
- Use proper indentation (spaces, not tabs)
- Add descriptive comments for complex logic
- Test with `/reload` in-game after changes

## Branch Strategy

### Branch Semantics - CRITICAL
- **`main` branch** = Retail / Stable releases
  - Version format: `X.Y.Z` (e.g., `0.1.0`)
  - For live WoW servers
  - Protected: requires PR and CI checks

- **`beta` branch** = PTR/Beta / Experimental
  - Version format: `X.Y.Z-beta` (e.g., `0.1.0-beta.1`)
  - For Beta/PTR WoW servers
  - Protected: requires PR and CI checks

### Version Bumping Rules
- Bump the version in `SpectrumFederation/SpectrumFederation.toc` whenever making a behavioral change (i.e., any change that affects the addon's functionality or user experience).
- Non-behavioral changes (such as documentation or comments) do not require a version bump.
- The `## Version:` field must be updated for any PR to `main` or `beta` that includes behavioral changes.
- CI will fail if version isn't bumped
- Release workflow automatically creates tags based on TOC version

### Release Rules - DO NOT VIOLATE
- **Beta versions can ONLY be released from `beta` branch**
- **Stable versions can ONLY be released from `main` branch**
- The release workflow enforces these rules automatically
- Never manually create or move git tags
- Never edit `.github/workflows/release.yml` to bypass version checks

## TOC File (`SpectrumFederation.toc`)

### Critical Fields
```
## Interface: 120000        # WoW patch version (12.0.0 = 120000)
## Version: 0.1.0-beta      # Addon version (MUST BE BUMPED)
## Title: Spectrum Federation
## Author: OsulivanAB
## Notes: Brief description
```

### Adding New Files
When creating new Lua files, add them to the TOC file load order:
```
# New files load AFTER their dependencies
SpectrumFederation.lua
modules/core.lua
modules/new_feature.lua    # Your new file here
```

## CI/CD Workflows

### Automated Workflows
1. **`validate-packaging.yml`** - Validates addon structure and version bump
2. **`linter.yml`** - Runs luacheck and yamllint
3. **`release.yml`** - Auto-creates tags and GitHub releases
4. **`update-readme-badges.yml`** - Updates README badges automatically
5. **`deploy-docs.yml`** - Deploys MkDocs to GitHub Pages

### When CI Fails
- **luacheck errors**: Fix Lua syntax/style issues
- **Version not bumped**: Update `## Version:` in TOC
- **Packaging validation**: Check WoW addon structure
- **Branch/version mismatch**: Ensure beta versions only on beta branch

## Documentation

### MkDocs Structure
- Documentation lives in `docs/`
- Uses Material for MkDocs theme
- Run locally: `pip install -r requirements-docs.txt && mkdocs serve`
- Auto-deploys to GitHub Pages on merge to `main`

### When Adding Features
1. Update relevant docs in `docs/`
2. Add code examples if helpful
3. Update `CHANGELOG.md` if it exists
4. Consider adding screenshots for UI features

## Common Tasks

### Adding a New Feature
1. Create feature branch from `beta` (for experimental) or `main` (for stable)
2. Add Lua files under `SpectrumFederation/`
3. Update TOC file to include new files
4. Bump version in TOC (`## Version:`)
5. Test in-game with `/reload`
6. Run `luacheck SpectrumFederation --only 0`
7. Create PR to appropriate branch

### Fixing a Bug
1. Create fix branch from the affected branch
2. Make the fix in `SpectrumFederation/`
3. Bump version in TOC
4. Test thoroughly in-game
5. Create PR with clear description

### Updating Dependencies
- There are no runtime dependencies (pure Lua addon)
- Dev dependencies in `requirements-docs.txt` for documentation
- Dev container handles Lua/luacheck installation

## Security Considerations

### Secrets and Tokens
- Repository uses `PAT_TOKEN` secret for workflow automation
- This token allows bypassing branch protection for automated commits
- **Never log or expose this token in workflow outputs**
- **Never use the token for purposes other than README badge updates**

### Protected Branches
- Both `main` and `beta` are protected
- Require pull request reviews
- Require status checks to pass
- Admin bypass only for automated workflows

## Testing

### In-Game Testing
1. Create symlink from WoW AddOns folder to `SpectrumFederation/`
2. Launch WoW and enable the addon
3. Use `/reload` after file changes
4. Check for Lua errors (default UI shows them in red)

### Lua Linting
```bash
# Check all addon files
luacheck SpectrumFederation --only 0

# Check specific file
luacheck SpectrumFederation/modules/core.lua
```

## Best Practices

### DO
✅ Bump version in TOC for every behavioral change  
✅ Use WoW API functions correctly  
✅ Test in-game before submitting PR  
✅ Follow existing code patterns  
✅ Add comments for complex logic  
✅ Update documentation when adding features  
✅ Use proper branch for your changes (beta for experimental, main for stable)  

### DON'T
❌ Edit workflow files to move or bypass version checks  
❌ Commit `BlizzardUI/` folder  
❌ Use Lua features beyond 5.1  
❌ Push directly to `main` or `beta` (use PRs)  
❌ Release beta versions from main branch  
❌ Release stable versions from beta branch  
❌ Forget to update TOC version  
❌ Use generic Lua libraries (io, os) - they're sandboxed in WoW  

## Getting Help

- Review existing code in `SpectrumFederation/modules/`
- Check Blizzard UI sources in `BlizzardUI/live/` or `BlizzardUI/beta/`
- Refer to [WoW API Documentation](https://wowpedia.fandom.com/wiki/World_of_Warcraft_API)
- See `docs/development/index.md` for local setup guide
- Check `.github/copilot-instructions.md` for additional context

## Summary for Quick Reference

**Language**: Lua 5.1 (WoW dialect)  
**Code Location**: `SpectrumFederation/` only  
**Manifest**: `SpectrumFederation/SpectrumFederation.toc` (MUST update version)  
**Branches**: `main` (stable) and `beta` (experimental)  
**Version Format**: `X.Y.Z` (main) or `X.Y.Z-beta.N` (beta, e.g., `0.0.13-beta.1`)  
**Testing**: Symlink to WoW, use `/reload`, run `luacheck`  
**Never Touch**: Release workflows (for tag management), `BlizzardUI/`  
