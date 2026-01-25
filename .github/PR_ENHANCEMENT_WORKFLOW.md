# PR Enhancement Workflow

This document describes the PR Enhancement workflow that was created for the SpectrumFederation addon.

## Overview

The PR Enhancement workflow (`pr-enhancement.yml`) is a manually-triggered GitHub Action that analyzes pull requests and helps enhance them with:

1. **Debug Logging**: Adds realistic debug logging using `SF.Debug` methods
2. **Documentation Updates**: Updates MkDocs documentation for user-facing changes
3. **Function Documentation**: Adds Lua doc comments to new/modified functions

## How to Use

### Via GitHub UI

1. Navigate to the **Actions** tab in the GitHub repository
2. Select **"PR Enhancement with Copilot"** from the workflow list
3. Click **"Run workflow"** button
4. Enter the **PR number** you want to enhance
5. Click **"Run workflow"** to start the process

### Via GitHub CLI

```bash
gh workflow run pr-enhancement.yml -f pr_number=<PR_NUMBER>
```

Example:
```bash
gh workflow run pr-enhancement.yml -f pr_number=42
```

## What the Workflow Does

1. **Fetches PR Information**: Retrieves details about the specified PR (branch, author, title)
2. **Checks Out PR Branch**: Creates a working copy of the PR branch
3. **Analyzes Files**: Identifies Lua and documentation files that were changed
4. **Creates Enhancement Branch**: Creates a new branch for the enhancements
5. **Generates Instructions**: Creates detailed enhancement guidelines based on project patterns
6. **Provides Guidance**: Shows what needs to be enhanced and how
7. **Creates Enhancement PR**: If changes are made, creates a new PR targeting the original PR branch

## Enhancement Guidelines

### Debug Logging

The workflow identifies where debug logging should be added:

**Add logging for:**
- Function entry/exit points for complex functions
- Error conditions and validation failures
- State changes in important operations
- Key decision points in control flow

**DO NOT add logging for:**
- Simple getters/setters
- Trivial utility functions
- Every single line of code

**Format:**
```lua
if SF.Debug then
    SF.Debug:Info("CATEGORY", "message with %s", arg)
end
```

**Available methods:**
- `SF.Debug:Info()` - Informational messages
- `SF.Debug:Error()` - Error conditions
- `SF.Debug:Warn()` - Warnings
- `SF.Debug:Verbose()` - Detailed debug info

**Categories:**
Use descriptive categories like: `"LOOT_HELPER"`, `"PROFILES"`, `"SYNC"`, `"UI"`, etc.

### Documentation Updates

The workflow checks if documentation needs updating:

**Update docs when:**
- New user-facing features are added
- Significant changes to existing features
- New developer APIs or patterns

**DO NOT update docs for:**
- Internal refactoring
- Minor bug fixes
- Trivial changes

**MkDocs Requirements:**
- Always add blank lines before and after bullet lists
- Always add blank lines before and after numbered lists
- Update `mkdocs.yml` navigation if adding new pages

### Function Documentation

The workflow ensures functions have proper Lua documentation:

**Format:**
```lua
-- Brief description of what the function does
-- @param paramName type Description
-- @param anotherParam type Description
-- @return returnType Description
function FunctionName(paramName, anotherParam)
    -- Implementation
end
```

**Example:**
```lua
-- Normalizes a player name to "Name-Realm" format
-- @param name string Player name (with or without realm)
-- @param defaultRealm string Realm to use if not in name
-- @return string Normalized "Name-Realm" identifier
function NormalizeNameRealm(name, defaultRealm)
    local normalized = SF.NameUtil.NormalizeNameRealm(name, defaultRealm)
    return normalized
end
```

## Workflow Output

### Artifacts

The workflow uploads the following artifacts:

1. **copilot_instructions.md**: Detailed enhancement guidelines
2. **pr_diff.patch**: The full diff of the PR for analysis

These artifacts are available for 7 days after the workflow run.

### Enhancement PR

If changes are made, the workflow creates a new PR with:

- **Title**: `[Enhancement] Add debug logging and docs for PR #<number>`
- **Base Branch**: The original PR's branch (not main/beta)
- **Description**: Details of what was enhanced and review guidelines

## Integration with GitHub Copilot

The workflow is designed to integrate with GitHub Copilot CLI/API. Currently, it provides:

1. **Framework**: Complete workflow structure for Copilot integration
2. **Instructions**: Detailed guidelines for what to enhance
3. **Manual Path**: Instructions for manual enhancement following the guidelines

Future enhancements can integrate actual Copilot CLI commands to automatically apply changes.

## Validation

The workflow includes validation steps:

1. **Linting**: Runs `lint_all.py` to ensure code quality
2. **YAML Validation**: Ensures workflow file is valid
3. **Permission Checks**: Verifies necessary permissions are granted

## Permissions Required

The workflow requires:

- `contents: write` - To create branches and commit changes
- `pull-requests: write` - To create enhancement PRs
- `issues: read` - To read PR information

## Important Notes

1. **Target Branch**: Enhancement PRs target the original PR branch, not main/beta
2. **Realistic Approach**: Focus on quality over quantity - don't add enhancements just to add them
3. **Code Patterns**: Follow existing patterns in the repository
4. **Manual Review**: Always review automated enhancements before merging

## Troubleshooting

### No Changes Detected

If the workflow completes but shows no changes:

1. The PR may already have appropriate debug logging and documentation
2. The changes may not require enhancement (e.g., minor refactoring)
3. Manual enhancement may be needed following the instructions

To enhance manually:

```bash
# Checkout the PR branch
git checkout <pr-branch>

# Create enhancement branch
git checkout -b enhance-pr-<number>

# Make your changes following copilot_instructions.md

# Commit and push
git add .
git commit -m "enhance: Add debug logging and documentation"
git push origin enhance-pr-<number>

# Create PR targeting the original PR branch
```

### Linting Failures

If linting fails after enhancement:

1. Review the linting output
2. Fix any issues manually
3. Re-run linters: `python3 .github/scripts/lint_all.py`
4. Commit the fixes

## Examples

### Example: Enhancing PR #42

```bash
# Run the workflow
gh workflow run pr-enhancement.yml -f pr_number=42

# Check workflow status
gh run list --workflow=pr-enhancement.yml

# Download artifacts if needed
gh run download <run-id>
```

### Example: Manual Enhancement

After the workflow runs, if manual enhancement is needed:

```bash
# Checkout the PR branch
git fetch origin
git checkout feature-branch

# Create enhancement branch
git checkout -b enhance-pr-42

# Add debug logging to key functions
# Update documentation
# Add function comments

# Commit changes
git add .
git commit -m "enhance: Add debug logging and documentation for PR #42"

# Push and create PR
git push origin enhance-pr-42
gh pr create --base feature-branch --title "[Enhancement] Debug logging for PR #42"
```

## See Also

- [Copilot Instructions](.github/copilot-instructions.md)
- [CI/CD Workflows](../docs/development/getting-started/workflows.md)
- [Development Guide](../docs/development/getting-started/index.md)
