# General Agent Instructions

These instructions apply to all GitHub Copilot agents working on the SpectrumFederation repository.

## Critical First Step: Version Bumping

**Before or immediately after making ANY code, feature, or behavioral changes:**

1. Open `SpectrumFederation/SpectrumFederation.toc`
2. Locate the line: `## Version: X.Y.Z` or `## Version: X.Y.Z-beta.N`
3. Update the version number based on your target branch:
   - **Beta branch**: Increment beta number (e.g., `0.4.0-beta.7` → `0.4.0-beta.8`)
   - **Main branch**: Increment version appropriately:
     - Patch version for bug fixes: `0.4.0` → `0.4.1`
     - Minor version for new features: `0.4.0` → `0.5.0`
     - Major version for breaking changes: `0.4.0` → `1.0.0`

**Why this is critical:**
- CI validation will FAIL if version is not bumped
- The `check-version-bump.py` script compares your version to the base branch
- No PR can be merged without passing this check
- Automated releases depend on version changes

## Repository Context

**Project**: World of Warcraft addon for guild loot management
**Language**: Lua 5.1 (WoW embedded interpreter)
**Key Files**:
- `SpectrumFederation/SpectrumFederation.toc` - Addon manifest (MUST bump version here)
- `SpectrumFederation/*.lua` - Addon code
- `.github/workflows/pr-*-validation.yml` - CI validation including version checks

## Workflow

1. **FIRST**: Bump version in `.toc` file
2. Make your code/documentation changes
3. Test changes (if code-related)
4. Run linters: `python3 .github/scripts/lint_all.py`
5. **VERIFY**: Check that version was bumped before committing
6. Commit changes with descriptive message
7. Create PR

## Common Pitfalls

❌ **Don't**: Make code changes without bumping version  
✅ **Do**: Bump version first, then make changes

❌ **Don't**: Forget to save the `.toc` file after editing  
✅ **Do**: Verify the change is saved and staged for commit

❌ **Don't**: Use the same version as the base branch  
✅ **Do**: Increment the version number appropriately

## Getting Help

If you're unsure about:
- Which version number to use: Check the current version in the base branch and increment appropriately
- What changes qualify for version bump: ALL code, feature, and behavioral changes require it
- How to check if you bumped it: Run `git diff SpectrumFederation/SpectrumFederation.toc` to see your changes

## Additional Context

See `.github/copilot-instructions.md` for detailed project-specific guidance on:
- Lua coding patterns
- WoW API usage
- Module structure
- Testing procedures
