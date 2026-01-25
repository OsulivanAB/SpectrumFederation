# Code Changes Agent Instructions

Instructions for agents making code changes to SpectrumFederation addon.

## ⚠️ MANDATORY FIRST STEP: Version Bump ⚠️

**DO THIS BEFORE WRITING ANY CODE:**

1. Open `SpectrumFederation/SpectrumFederation.toc`
2. Find: `## Version: X.Y.Z-beta.N` (or `X.Y.Z` for main branch)
3. Update to: Next version number
   - Beta branch: `0.4.0-beta.7` → `0.4.0-beta.8`
   - Main branch: `0.4.0` → `0.4.1` (patch) or `0.5.0` (minor) or `1.0.0` (major)
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
- [ ] Code follows Lua 5.1 restrictions
- [ ] Uses namespace pattern correctly
- [ ] Has debug logging for important operations
- [ ] New files added to TOC in correct order
- [ ] Passes `luacheck SpectrumFederation --only 0`
- [ ] Tested in-game (if possible)
- [ ] Git diff shows version change in `.toc` file

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
