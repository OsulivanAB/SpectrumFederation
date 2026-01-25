# Code Changes Agent Instructions

Instructions for agents making code changes to SpectrumFederation addon.

## ⚠️ MANDATORY FIRST STEP: Version Bump ⚠️

**DO THIS BEFORE WRITING ANY CODE:**

1. Open `SpectrumFederation/SpectrumFederation.toc`
2. Find: `## Version: X.Y.Z-beta.N` (or `X.Y.Z` for main branch)
3. Update to: Next version number following Semantic Versioning rules:

   **For Beta branch:**
   - Always increment beta number: `0.4.0-beta.7` → `0.4.0-beta.8`
   
   **For Main branch (use Semantic Versioning):**
   - **PATCH** (`X.Y.Z` → `X.Y.Z+1`): Bug fixes, documentation, small tweaks
     - Example: `0.4.0` → `0.4.1`
   - **MINOR** (`X.Y.Z` → `X.Y+1.0`): New features, backward compatible changes
     - Example: `0.4.0` → `0.5.0`
   - **MAJOR** (`X.Y.Z` → `X+1.0.0`): Breaking changes, incompatible changes
     - Example: `0.4.0` → `1.0.0`
   
   **Quick decision guide:**
   - Small fix or tweak? → Use PATCH
   - Adding new feature? → Use MINOR
   - Breaking existing functionality? → Use MAJOR
   - Beta branch? → Increment beta number

4. Save and stage this change

**If you skip this step, CI will fail and your PR will be rejected.**

## Code Changes Workflow

### 1. Version Bump (MANDATORY)
```bash
# Edit SpectrumFederation/SpectrumFederation.toc
# Update ## Version: line
```

### 2. Understand the Change
- Read the issue/task description carefully
- Review existing code in the affected area
- Check `.github/copilot-instructions.md` for patterns and conventions
- Identify which modules need changes

### 3. Make Code Changes
Follow the patterns in `.github/copilot-instructions.md`:
- Use `local addonName, SF = ...` namespace pattern
- Add debug logging: `SF.Debug:Info("CATEGORY", "message")`
- Use helper functions: `SF:PrintSuccess()`, `SF:PrintError()`, etc.
- Follow Lua 5.1 restrictions (no goto, bitwise ops, io/os libs)
- Use WoW API functions properly

### 4. Update TOC Load Order (if adding new files)
If you create a new `.lua` file:
1. Add it to `SpectrumFederation/SpectrumFederation.toc`
2. Place it AFTER its dependencies
3. Place it BEFORE files that depend on it
4. See the copilot instructions for the correct load order pattern

### 5. Test Your Changes
```bash
# Lint the code
luacheck SpectrumFederation --only 0

# Or use unified linter
python3 .github/scripts/lint_all.py
```

In-game testing (if possible):
- Copy addon to WoW's `Interface/AddOns/`
- Use `/reload` to load changes
- Test affected functionality
- Check for Lua errors: `/console scriptErrors 1`

### 6. Verify Version Bump
```bash
# Check that version was actually changed
git diff SpectrumFederation/SpectrumFederation.toc

# Should show a line like:
# -## Version: 0.4.0-beta.7
# +## Version: 0.4.0-beta.8
```

**Verify you chose the correct version bump:**
- Bug fix or small change? Should be PATCH (e.g., `0.4.0` → `0.4.1`)
- New feature? Should be MINOR (e.g., `0.4.0` → `0.5.0`)
- Breaking change? Should be MAJOR (e.g., `0.4.0` → `1.0.0`)
- Beta branch? Should increment beta number (e.g., `0.4.0-beta.7` → `0.4.0-beta.8`)

### 7. Commit
```bash
git add SpectrumFederation/SpectrumFederation.toc
git add [other changed files]
git commit -m "Brief description of changes"
```

## Common Code Patterns

### Adding a New Module
```lua
local addonName, SF = ...

local MyModule = SF.MyModule or {}
SF.MyModule = MyModule

function MyModule:SomeFunction()
    if SF.Debug then
        SF.Debug:Info("MYMODULE", "Function called")
    end
    -- Implementation
end
```

### Adding to Existing Module
- Maintain existing patterns
- Use the same debug category
- Follow the module's conventions

### User-Facing Messages
```lua
SF:PrintSuccess("Operation completed!")
SF:PrintError("Operation failed!")
SF:PrintWarning("Warning message")
SF:PrintInfo("Information message")
```

## Checklist Before Committing

- [ ] **CRITICAL**: Version bumped in `SpectrumFederation/SpectrumFederation.toc`
- [ ] **CRITICAL**: Version bump follows semantic versioning rules (see below)
- [ ] Code follows Lua 5.1 restrictions
- [ ] Uses namespace pattern correctly
- [ ] Has debug logging for important operations
- [ ] New files added to TOC in correct order
- [ ] Passes `luacheck SpectrumFederation --only 0`
- [ ] Tested in-game (if possible)
- [ ] Git diff shows version change in `.toc` file

## Semantic Versioning Guide

**SpectrumFederation follows [Semantic Versioning 2.0.0](https://semver.org/)** for stable releases.

### Version Format: `MAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH-beta.N`

**When to use each version bump:**

### PATCH Version (`X.Y.Z` → `X.Y.Z+1`)
Increment for **backward-compatible bug fixes** and minor changes:

✅ **Use PATCH for:**
- Bug fixes that don't change functionality
- Typo corrections
- Performance improvements with no API changes
- Internal refactoring (no external behavior change)
- Documentation updates (if shipped with code)
- Dependency updates (patch-level only)

❌ **Don't use PATCH for:**
- New features (even small ones)
- New slash commands
- UI changes users will notice

**Examples:**
- Fixed loot log validation error → `0.4.0` → `0.4.1`
- Performance optimization in sync protocol → `1.2.3` → `1.2.4`
- Fix crash when profile has no members → `0.5.0` → `0.5.1`

### MINOR Version (`X.Y.Z` → `X.Y+1.0`)
Increment for **new features** that are **backward-compatible**:

✅ **Use MINOR for:**
- New features or functionality
- New slash commands
- New UI windows or panels
- New settings or configuration options
- Deprecating features (marking for future removal, but still working)
- New profile types or loot log event types
- Adding new optional API methods
- Dependency updates (minor-level)

❌ **Don't use MINOR for:**
- Breaking changes to existing features
- Removing commands or features
- Incompatible database changes

**Examples:**
- Add new `/sf export` command → `0.4.0` → `0.5.0`
- New standalone settings window → `0.4.0` → `0.5.0`
- Add new "raid history" feature → `1.2.3` → `1.3.0`
- New LootLog event type (backward compatible) → `0.8.0` → `0.9.0`

### MAJOR Version (`X.Y.Z` → `X+1.0.0`)
Increment for **incompatible or breaking changes**:

✅ **Use MAJOR for:**
- Breaking API changes
- Removing features, commands, or UI elements
- Incompatible database schema changes
- Changes requiring user action (data migration, reset)
- WoW expansion updates (11.x.x → 12.0.0)
- Major refactoring changing user workflows
- Removing deprecated features

❌ **Don't use MAJOR for:**
- Bug fixes (even critical ones)
- New features that don't break existing ones
- Internal changes users don't see

**Examples:**
- Remove old `/sf lootprofile` command → `0.9.0` → `1.0.0`
- Incompatible profile format change → `1.5.0` → `2.0.0`
- WoW expansion 12.0 update → `1.9.0` → `2.0.0`
- Complete sync protocol rewrite (incompatible) → `3.2.0` → `4.0.0`

### Beta Versions (`X.Y.Z-beta.N`)
For beta branch only:

✅ **Always increment beta number:**
- `0.4.0-beta.7` → `0.4.0-beta.8`
- `0.4.0-beta.99` → `0.4.0-beta.100`

The beta base version (`0.4.0`) is determined by the release manager and stays constant until promoted to main.

### Quick Decision Tree

```
Is this for beta branch? → YES → Increment beta number (N+1)
                        ↓ NO
Does it break existing functionality? → YES → MAJOR (X+1.0.0)
                                     ↓ NO
Does it add new features? → YES → MINOR (X.Y+1.0)
                         ↓ NO
Is it a bug fix or small change? → YES → PATCH (X.Y.Z+1)
```

### Examples by Change Type

| Change Description | Version Bump | Example |
|-------------------|--------------|---------|
| Fix crash when clicking loot button | PATCH | `0.4.1` → `0.4.2` |
| Add new settings window | MINOR | `0.4.0` → `0.5.0` |
| Remove old database format | MAJOR | `0.9.5` → `1.0.0` |
| Optimize sync performance | PATCH | `1.2.3` → `1.2.4` |
| New `/sf export` command | MINOR | `0.8.0` → `0.9.0` |
| Update for WoW patch 12.0 | MAJOR | `2.3.0` → `3.0.0` |
| Beta iteration | Beta +1 | `0.4.0-beta.7` → `0.4.0-beta.8` |

## Version Bump Verification

Before creating a PR, run:
```bash
# This is what CI runs - make sure it passes locally
python3 .github/scripts/check_version_bump.py beta  # or 'main' for main branch
```

If this fails locally, it will fail in CI. Fix it before pushing!

## Emergency: Forgot to Bump Version?

If you already committed changes without bumping version:
```bash
# Edit the .toc file and bump version
# Then amend your last commit:
git add SpectrumFederation/SpectrumFederation.toc
git commit --amend --no-edit

# Or create a new commit if you've already pushed:
git add SpectrumFederation/SpectrumFederation.toc
git commit -m "Bump version for code changes"
```

## See Also

- `.github/copilot-instructions.md` - Full project conventions and patterns
- `.github/agents/general.md` - General agent instructions
- `.github/workflows/pr-beta-validation.yml` - CI validation workflow
