# Promoting Beta to Main

This guide explains how to promote a tested beta release to the stable `main` branch using the automated promotion workflow.

## Overview

Promotion is a **manual admin-triggered process** that:

1. Merges `beta` → `main` with special handling
2. Removes the `-beta` suffix from the version
3. Updates Interface version using Blizzard API
4. Updates changelog and README badges
5. Deploys documentation to GitHub Pages
6. Creates a stable GitHub release
7. Fast-forwards `beta` to match `main`

**Who can promote**: Repository admins only

## Prerequisites

Before promoting, ensure:

1. ✅ Beta release has been tested thoroughly
2. ✅ All features work as expected in-game
3. ✅ No critical bugs reported
4. ✅ CI checks pass on beta branch
5. ✅ Community feedback is positive (if applicable)

## Promotion Steps

### 1. Test with Dry-Run (Recommended)

Always test the promotion first:

1. Go to **Actions** → **Promote Beta to Main**
2. Click **Run workflow**
3. Set:
   - **Use workflow from**: `beta`
   - **Dry run**: `true` ✅
4. Click **Run workflow**

**What happens in dry-run**:
- All steps execute
- No actual changes made to branches/releases
- Summary shows what WOULD happen
- Review output carefully

### 2. Run Actual Promotion

Once dry-run looks good:

1. Go to **Actions** → **Promote Beta to Main**
2. Click **Run workflow**
3. Set:
   - **Use workflow from**: `beta`
   - **Dry run**: `false`
4. Click **Run workflow**

### 3. Monitor Workflow

Watch the workflow progress:

- ✅ **Pre-merge validation** - Lint and package checks
- ✅ **Merge beta to main** - Merges with version cleanup
- ✅ **Update changelog** - Updates CHANGELOG.md
- ✅ **Update README** - Updates badges
- ✅ **Deploy docs** - Publishes to GitHub Pages
- ✅ **Publish stable release** - Creates GitHub release
- ✅ **Fast-forward beta** - Syncs beta to main
- ✅ **Summary** - Shows completion status

### 4. Verify Promotion

After workflow completes:

1. **Check main branch**:
   - Version in TOC should be `X.Y.Z` (no `-beta`)
   - Commit history shows merge commit
   - CHANGELOG.md has stable release section

2. **Check GitHub release**:
   - New release created with stable version
   - Zip file attached
   - Not marked as prerelease

3. **Check beta branch**:
   - Beta is now in sync with main
   - No divergence between branches

4. **Check documentation**:
   - GitHub Pages updated
   - Reflects current stable version

## Version Format Changes

**Before promotion** (beta):
```
## Version: 0.0.17-beta.1
## Interface: 110207
```

**After promotion** (main):
```
## Version: 0.0.17
## Interface: 110207
```

**Note**: Interface version is fetched from Blizzard's LIVE API (not beta)

## What If Promotion Fails?

### Pre-merge Validation Fails

**Problem**: Lint or packaging validation fails

**Solution**:
1. Fix issues in beta branch
2. Push fixes
3. Wait for CI to pass
4. Retry promotion

### Merge Conflicts

**Problem**: Beta can't merge cleanly into main

**Solution**:
1. Manually merge main → beta locally
2. Resolve conflicts
3. Push to beta
4. Retry promotion

### Stable Release Has Issues

**Problem**: After promotion, issues are discovered

**Solution**: Use the [rollback workflow](workflows.md#7-rollback-workflow-rollback-releaseyml)

1. Go to **Actions** → **Rollback Release**
2. Enter the release tag (e.g., `v0.0.17`)
3. Test with `dry_run: true` first
4. Run actual rollback

**What rollback does**:
- Reverts the promotion merge commit
- Deletes the GitHub release
- Deletes the release tag
- Restores previous CHANGELOG.md

## After Promotion

### Continue Development

1. **New features** still go to beta first:
   ```bash
   git checkout beta
   git pull
   git checkout -b feature/my-feature
   ```

2. **Version bump** for next beta:
   ```
   ## Version: 0.0.18-beta.1
   ```

3. **Beta releases** continue automatically after merge

### Hotfixes to Main

For urgent fixes to stable release:

1. Create hotfix branch from main:
   ```bash
   git checkout main
   git pull
   git checkout -b hotfix/critical-bug
   ```

2. Fix the issue and bump version:
   ```
   ## Version: 0.0.18  # Increment from 0.0.17
   ```

3. Create PR to main

4. After merge, sync beta:
   ```bash
   git checkout beta
   git merge main
   git push
   ```

## Promotion Checklist

Use this checklist for each promotion:

- [ ] Beta release tested in-game
- [ ] No critical bugs reported
- [ ] CI checks pass on beta
- [ ] Dry-run promotion completed successfully
- [ ] Reviewed dry-run output
- [ ] Ran actual promotion
- [ ] Verified main branch version
- [ ] Verified GitHub release created
- [ ] Verified beta fast-forwarded
- [ ] Verified documentation deployed
- [ ] Tested addon from stable release zip
- [ ] Announced release to community (if applicable)

## Troubleshooting

### Workflow Won't Trigger

- Ensure you're a repository admin
- Check branch protection rules
- Verify PAT_TOKEN secret is configured

### Fast-Forward Fails

- Beta has diverged from main
- Manually sync: `git checkout beta && git merge main && git push`

### Documentation Not Deploying

- Check deploy-docs workflow status
- Verify GitHub Pages is enabled
- Check for build errors in workflow logs

## Additional Resources

- [CI/CD Workflows Guide](workflows.md) - Complete workflow documentation
- [Rollback Process](workflows.md#7-rollback-workflow-rollback-releaseyml) - How to revert a promotion
