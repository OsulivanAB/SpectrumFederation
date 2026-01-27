# Documentation Agent Instructions

Instructions for agents working on documentation for SpectrumFederation.

## Documentation vs Code Changes

**Important distinction:**
- **Pure documentation changes** (markdown files, comments): May not require version bump
- **Code changes that affect behavior** + documentation: MUST bump version
- **When in doubt**: Bump the version - it's safer

## When Version Bump IS Required

Bump version in `SpectrumFederation/SpectrumFederation.toc` if you're also:
- Changing any `.lua` files
- Modifying the `.toc` file itself (other than version)
- Adding/removing files that affect addon functionality
- Updating in-game text/messages/UI

## When Version Bump May NOT Be Required

Pure documentation changes in:
- `docs/` directory (MkDocs documentation)
- `README.md`
- `CHANGELOG.md` (unless also releasing)
- Comments in code (if no functional changes)
- `.github/` markdown files (this file, copilot-instructions.md, etc.)

**However**: If CI fails asking for a version bump, go ahead and bump it. The scripts are conservative.

## Documentation Workflow

### 1. Assess If Version Bump Needed
- Only docs changed? Probably not needed
- Any code changed too? **YES, BUMP VERSION FIRST**

### 2. Make Documentation Changes

#### MkDocs Documentation (`docs/`)
- Use Material for MkDocs syntax
- **CRITICAL**: Add blank lines before and after lists
  ```markdown
  Some text.
  
  - Item 1
  - Item 2
  
  More text.
  ```
- Test locally: `mkdocs serve`
- Validate: `python3 .github/scripts/validate_docs.py`

#### README Updates
- Keep badges up to date (version, status)
- Maintain consistent formatting
- Update links if structure changes

#### Code Comments
- Match existing comment style
- Don't over-comment obvious code
- Do document complex logic or WoW API usage

### 3. Test Documentation Build
```bash
# Install dependencies
pip install -r requirements-docs.txt

# Test local build
mkdocs serve
# Open browser to http://localhost:8000

# Validate
python3 .github/scripts/validate_docs.py
```

### 4. Lint (if applicable)
```bash
# Runs markdown linting via mdformat (if configured)
python3 .github/scripts/lint_all.py
```

### 5. Commit Changes
```bash
git add docs/
# or
git add README.md
# etc.

git commit -m "Update documentation for [feature/fix]"
```

## MkDocs Formatting Rules

### Lists MUST Have Blank Lines
```markdown
# ❌ WRONG - Will render incorrectly
**Parameters:**
- param1 - Description
- param2 - Description

# ✅ CORRECT - Renders properly
**Parameters:**

- param1 - Description
- param2 - Description

More content here.
```

### Code Blocks
```markdown
# Use triple backticks with language
```lua
local addonName, SF = ...
```
```

### Admonitions (Material theme)
```markdown
!!! note
    This is a note

!!! warning
    This is a warning

!!! danger
    Critical information
```

## Documenting New Features

When documenting a new feature (which likely involves code changes):

1. **BUMP VERSION FIRST** (because you're changing code)
2. Add feature documentation in `docs/features/` or appropriate section
3. Update `docs/index.md` if needed
4. Add to `CHANGELOG.md` (goes in `## [Unreleased - Beta]` section)
5. Update API documentation if exposing new functions
6. Test documentation build

## Checklist for Documentation PRs

- [ ] Determine if version bump needed (when in doubt, bump it)
- [ ] If version bump needed: Updated `SpectrumFederation/SpectrumFederation.toc`
- [ ] MkDocs: Blank lines before/after all lists
- [ ] MkDocs: Tested locally with `mkdocs serve`
- [ ] Validated with `python3 .github/scripts/validate_docs.py`
- [ ] All links work and point to correct locations
- [ ] Code examples are syntactically correct
- [ ] Formatting is consistent with existing docs

## Documentation Standards

### File Organization
```
docs/
├── index.md                 # Home page
├── getting-started.md       # Installation and setup
├── features/                # Feature documentation
│   ├── loot-helper.md
│   └── profiles.md
└── development/             # Developer docs
    ├── api.md
    └── contributing.md
```

### Style Guide
- Use active voice: "Click the button" not "The button should be clicked"
- Be concise but clear
- Include examples for complex concepts
- Use screenshots for UI features (save to `docs/images/`)
- Link to related documentation

### Code Examples
- Must be syntactically correct
- Should be minimal but complete
- Include context (what module, when to use)
- Use real WoW API calls, not pseudocode

## See Also

- `.github/copilot-instructions.md` - Project conventions
- `.github/agents/general.md` - General agent instructions
- `mkdocs.yml` - MkDocs configuration
- `requirements-docs.txt` - Documentation dependencies
