# GitHub Copilot Agent Instructions for SpectrumFederation

## Critical Version Management Requirements

**⚠️ ABSOLUTELY CRITICAL - VERSION BUMPING IS MANDATORY ⚠️**

Every GitHub Copilot agent working on this repository **MUST** follow these version bumping rules:

### When to Bump Version

**ALWAYS bump the version** when making ANY of the following changes:
- Adding new features or functionality
- Modifying existing behavior or logic
- Fixing bugs that change code behavior
- Updating UI elements or interfaces
- Changing database schema or data structures
- Modifying API interactions or integrations
- Adding, removing, or modifying Lua files
- Changing workflow logic or CI/CD behavior

**DO NOT bump the version** for:
- Documentation-only changes (README, docs/, comments)
- Updating `.gitignore` or other metadata files
- Formatting or style changes that don't affect behavior
- Fixing typos in comments or strings (unless user-facing)

### How to Bump Version

1. **Location**: `SpectrumFederation/SpectrumFederation.toc`
2. **Field**: `## Version:` (line near the top of file)
3. **Format**:
   - For beta branch: `X.Y.Z-beta.N` (e.g., `0.3.1-beta.22`)
   - For main branch: `X.Y.Z` (e.g., `0.3.1`)

### Version Bumping Process

**STEP 1: Check current version**
```bash
grep "^## Version:" SpectrumFederation/SpectrumFederation.toc
```

**STEP 2: Determine new version**
- Increment the appropriate number based on change scope:
  - **Patch** (Z): Bug fixes, minor changes (e.g., `0.3.1` → `0.3.2`)
  - **Minor** (Y): New features, significant changes (e.g., `0.3.1` → `0.4.0`)
  - **Major** (X): Breaking changes, major releases (e.g., `0.3.1` → `1.0.0`)
- For beta: Increment beta number (e.g., `0.3.1-beta.21` → `0.3.1-beta.22`)

**STEP 3: Update the TOC file**
Edit the `## Version:` line in `SpectrumFederation/SpectrumFederation.toc`

**STEP 4: Verify the change**
```bash
git diff SpectrumFederation/SpectrumFederation.toc
```

### CI/CD Enforcement

- **CI will FAIL** if version is not bumped for behavioral changes
- The `check_version_bump.py` script compares current branch to base branch
- PRs to beta MUST have version bumped unless docs-only
- Version format MUST match branch (`-beta` suffix for beta branch only)

### Before Every PR Submission

**ALWAYS include this checklist in your workflow:**

```markdown
- [ ] Identified type of change (behavioral vs non-behavioral)
- [ ] Checked current version in SpectrumFederation.toc
- [ ] Determined appropriate new version number
- [ ] Updated ## Version: line in SpectrumFederation.toc
- [ ] Verified version format matches target branch
- [ ] Committed version bump with other changes
```

## Additional Instructions

### TOC File Management

The `SpectrumFederation.toc` file is **critical** and must be handled carefully:

1. **Load Order**: Files must be listed in dependency order
2. **Version Field**: Must be bumped for every behavioral change
3. **Interface Field**: Automatically updated by CI (don't manually change)
4. **Dependencies**: Listed at the top of the file

### File Structure

When adding new files:
1. Place in appropriate directory (`modules/` or `modules/LootHelper/`)
2. **Add to `.toc` file** in correct load order
3. Use namespace pattern: `local addonName, SF = ...`
4. **Bump version** in `.toc` file

### Branch Strategy

- **beta**: Development and testing (use `-beta` suffix)
- **main**: Stable releases (no suffix)
- PRs should target **beta** by default
- Only admins promote beta → main

### Keeping Instructions Up-to-Date

**GitHub agents are responsible for maintaining these instructions:**

1. **When making significant changes to the codebase**:
   - Update `.github/agents/instructions.md` to reflect new patterns
   - Update `.github/copilot-instructions.md` for general guidance
   - Ensure both files stay synchronized on critical rules

2. **When adding new workflows or automation**:
   - Document new CI/CD requirements in both instruction files
   - Update troubleshooting sections

3. **When changing project structure**:
   - Update file structure documentation
   - Update load order examples
   - Document new directories or patterns

4. **Periodic review**:
   - Check if instructions match actual codebase patterns
   - Verify all critical rules are still enforced
   - Update examples to use current code

### Synchronization Between Instruction Files

**Both files should be kept in sync for:**
- Version bumping rules (CRITICAL)
- Branch strategy
- TOC file management
- File structure guidelines
- CI/CD enforcement rules

**Differences allowed:**
- `.github/copilot-instructions.md`: More detailed, includes code examples
- `.github/agents/instructions.md`: Concise, focused on critical rules for agents

## Emergency Contacts

If you encounter issues with:
- Version bumping requirements
- CI/CD failures
- Branch/release process

Consult:
- `docs/development/workflows.md` - Comprehensive workflow documentation
- `.github/copilot-instructions.md` - Detailed coding guidelines
- `.github/scripts/check_version_bump.py` - Version validation logic

## References

- **Copilot Instructions**: `.github/copilot-instructions.md`
- **Workflow Documentation**: `docs/development/workflows.md`
- **CI Scripts**: `.github/scripts/`
- **TOC File**: `SpectrumFederation/SpectrumFederation.toc`
