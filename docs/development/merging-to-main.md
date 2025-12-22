# Merging Beta to Main

This guide explains how to properly merge changes from the `beta` branch into `main` for release, following best practices for contributors without admin privileges.

## Branch Strategy Overview

Our repository follows a dual-branch strategy:

- **`beta`** - Experimental features and beta releases (version format: `X.Y.Z-beta.N`)
- **`main`** - Stable releases for production (version format: `X.Y.Z`)

Both branches are protected and require pull requests with passing CI checks before merging.

## Standard Merge Process (Non-Admin)

For contributors without admin privileges, follow this process to propose a beta-to-main merge:

### Step 1: Create a Release Branch

Create a new branch from `beta` specifically for the release:

```bash
git checkout beta
git pull origin beta
git checkout -b release/v0.0.X
```

/// tip | Branch Naming
Use descriptive names like `release/v0.0.16` to clearly indicate this is a release preparation branch.
///

### Step 2: Update Version Number

Edit `SpectrumFederation/SpectrumFederation.toc` and remove the `-beta.N` suffix from the version:

**Before:**
```toc
## Version: 0.0.16-beta.1
```

**After:**
```toc
## Version: 0.0.16
```

/// warning | Critical Step
The version **must not** contain `-beta` when merging to `main`. The CI validation will fail otherwise.
///

### Step 3: Commit Changes

```bash
git add SpectrumFederation/SpectrumFederation.toc
git commit -m "chore: prepare v0.0.16 release"
git push origin release/v0.0.X
```

/// info | Changelog Automation
The `CHANGELOG.md` is automatically updated by the GitHub Actions workflow when changes are pushed. You don't need to manually edit it.
///

### Step 4: Open Pull Request to Main

1. Go to GitHub and create a new Pull Request
2. Set **base** branch to `main`
3. Set **compare** branch to your `release/v0.0.X` branch
4. Title: `Release v0.0.X`
5. Description: Summarize key changes from beta

/// example | PR Description Template
```markdown
## Release v0.0.16

This PR merges beta changes into main for a stable release.

### Major Changes
- Settings UI redesign with auto-scaling banner
- Debug logging system
- Loot profile management

### CI Status
- ✅ Linter passing
- ✅ Version bump validated
- ✅ Package structure validated
```
///

### Step 5: Wait for CI and Review

- All CI checks must pass (linter, version validation, packaging)
- Request review from maintainers
- Address any feedback or conflicts
- Once approved, a maintainer will merge the PR

### Step 6: Sync Beta After Release

After the release is merged to main, sync beta with the new stable version:

```bash
git checkout beta
git pull origin main
git push origin beta
```

This ensures beta includes the version update from main.

## Common Issues

### Merge Conflicts

If conflicts occur, they typically involve:

- Version numbers in `.toc` file
- Changelog entries
- Files deleted in one branch but modified in another

**Resolution:** In most cases, prefer the beta branch's version of files.

### Version Validation Failure

Error: `Version must not contain 'beta' when merging to main`

**Solution:** Ensure the version in `.toc` file has the `-beta.N` suffix removed.

## Release Automation

After merging to main:

1. **Release workflow** automatically creates a GitHub release and git tag
2. **Changelog workflow** updates `CHANGELOG.md` with new entries
3. **Badge workflow** updates README badges with the new version
4. **Docs deployment** publishes documentation to GitHub Pages

/// success | Automation Benefits
These workflows ensure consistent releases without manual intervention for version tagging and documentation deployment.
///

## Best Practices

1. **Always test in beta first** - New features should be thoroughly tested in beta before main
2. **Version bump required** - Every behavioral change needs a version increment
3. **Update changelog** - Keep `CHANGELOG.md` current with all changes
4. **One release at a time** - Don't merge multiple beta versions to main simultaneously
5. **Clean commit history** - Squash or clean up commits before merging if needed

## Related Documentation

- [Getting Started](index.md) - Development environment setup
- [Naming Conventions](naming-conventions.md) - Code style guide
- [CI/CD Workflows](https://github.com/OsulivanAB/SpectrumFederation/tree/main/.github/workflows) - Automation details
