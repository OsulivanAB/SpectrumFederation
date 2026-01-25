# Creating the PR for PR Enhancement Workflow

Since the GitHub CLI authentication is not available in this environment, please create the PR manually using one of the following methods:

## Method 1: GitHub Web UI

1. Go to https://github.com/OsulivanAB/SpectrumFederation
2. Click on "Pull requests" tab
3. Click "New pull request"
4. Set **base** to: `Feature/Loot-Helper-Window`
5. Set **compare** to: `copilot/create-manual-workflow`
6. Click "Create pull request"
7. Copy the PR body from below

## Method 2: GitHub CLI (with proper authentication)

```bash
cd /home/runner/work/SpectrumFederation/SpectrumFederation
gh pr create \
  --base Feature/Loot-Helper-Window \
  --head copilot/create-manual-workflow \
  --title "feat: Add PR Enhancement Workflow with Copilot Integration" \
  --body-file /tmp/pr_body.md
```

## PR Details

**Title:**
```
feat: Add PR Enhancement Workflow with Copilot Integration
```

**Base Branch:** `Feature/Loot-Helper-Window`

**Head Branch:** `copilot/create-manual-workflow`

**Description:**

```markdown
## Summary

This PR adds a new GitHub Actions workflow that can be manually triggered to enhance pull requests with:

1. **Debug Logging**: Realistic debug logging using SF.Debug methods
2. **Documentation Updates**: MkDocs documentation for user-facing changes
3. **Function Documentation**: Lua doc comments for new/modified functions

## How It Works

The workflow is triggered manually via `workflow_dispatch` with a PR number as input:

1. Fetches PR information and checks out the PR branch
2. Analyzes changed Lua and doc files
3. Creates enhancement instructions based on project patterns
4. Provides guidance for manual enhancement
5. Creates a new PR targeting the original PR branch if changes are made

## Key Features

- ✅ Manual trigger with PR number input
- ✅ Analyzes PR diff and identifies Lua files
- ✅ Creates detailed enhancement instructions
- ✅ Follows existing debug logging patterns (SF.Debug)
- ✅ Follows Lua documentation format
- ✅ Respects MkDocs formatting requirements
- ✅ Creates PR targeting the original PR (not main/beta)
- ✅ Uploads artifacts (instructions + diff) for reference
- ✅ Validates with linters before pushing

## Usage

```bash
# Via GitHub UI:
# 1. Go to Actions tab
# 2. Select "PR Enhancement with Copilot" workflow
# 3. Click "Run workflow"
# 4. Enter PR number
# 5. Click "Run workflow"

# Via GitHub CLI:
gh workflow run pr-enhancement.yml -f pr_number=123
```

## Integration Note

The workflow currently provides a framework for Copilot integration. The actual code modifications can be:

1. **Automated**: Through GitHub Copilot CLI/API integration (future enhancement)
2. **Manual**: Following the generated instructions and reviewing the diff

## Testing

- ✅ YAML syntax validated
- ✅ Linting passed (yamllint)
- ✅ Follows existing workflow patterns
- ✅ Permissions configured correctly

## Related

Resolves the requirement to create a manual workflow for PR enhancement with Copilot-guided improvements.

---
*This PR targets the Feature/Loot-Helper-Window branch as requested.*
```

## Files Changed

- `.github/workflows/pr-enhancement.yml` - New workflow file
- `.github/PR_ENHANCEMENT_WORKFLOW.md` - Documentation for the workflow
- `.github/CREATE_PR_INSTRUCTIONS.md` - This file

## Verification

The workflow has been:
- ✅ Created and committed
- ✅ Validated (YAML syntax)
- ✅ Linted (yamllint passed)
- ✅ Pushed to `copilot/create-manual-workflow` branch
- ⏳ PR creation pending (requires manual action or proper authentication)
