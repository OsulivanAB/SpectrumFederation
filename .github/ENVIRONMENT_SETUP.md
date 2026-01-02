# GitHub Environment Setup

This document explains how to configure GitHub Environments for the SpectrumFederation repository workflows.

## Required Environment: `documentation-sync`

The PR Beta Documentation Sync workflow requires a GitHub Environment called `documentation-sync` with required reviewers configured. This ensures that documentation analysis is only performed when a maintainer explicitly approves it.

### Setup Instructions

1. **Navigate to Repository Settings**
   - Go to your repository on GitHub
   - Click on "Settings" tab
   - Select "Environments" from the left sidebar

2. **Create the Environment**
   - Click "New environment"
   - Name: `documentation-sync`
   - Click "Configure environment"

3. **Configure Required Reviewers**
   - Under "Deployment protection rules"
   - Check "Required reviewers"
   - Add maintainers/admins who should approve documentation sync runs
   - Recommended: Add at least 1-2 trusted maintainers
   - Click "Save protection rules"

4. **Optional: Set Environment Secrets** (if needed in future)
   - You can add environment-specific secrets here
   - Currently not required for this workflow

### How It Works

When a PR is opened to the `beta` branch:

1. The "PR Beta Documentation Sync" workflow will appear in the Actions list
2. The workflow shows as "Waiting" with status "Review pending deployments"
3. A maintainer clicks "Review pending deployments"
4. They see the `documentation-sync` environment requiring approval
5. After approval, the workflow runs and analyzes code changes
6. The workflow creates a documentation PR if changes are needed

### Benefits

- **Prevents unnecessary runs**: Documentation analysis only runs when needed
- **Resource control**: Avoids consuming API quota for every PR update
- **Intentional action**: Ensures documentation updates are done deliberately
- **Maintainer oversight**: Keeps quality control in maintainer hands

### Manual Override

Maintainers can also trigger the workflow manually:

1. Go to Actions → PR Beta Documentation Sync
2. Click "Run workflow"
3. Enter the PR number
4. Approve the environment when prompted
5. Workflow will run for that specific PR

## Additional Environments

Currently, only the `documentation-sync` environment is required. Future workflows may require additional environments as the project grows.

## Troubleshooting

### Workflow doesn't appear on PRs

- Verify the workflow file is in `.github/workflows/pr-beta-docs-sync.yml`
- Check that the PR targets the `beta` branch
- Ensure the workflow is enabled in the Actions tab

### Can't approve environment

- Verify you are listed as a required reviewer for the environment
- Check that you have appropriate repository permissions (Write or Admin)
- Ensure you're not the PR author (GitHub requires different reviewer)

### Workflow fails after approval

- Check the workflow logs in the Actions tab
- Verify GITHUB_TOKEN has correct permissions (contents: write, pull-requests: write)
- Ensure the PR is still open and targets beta branch

## References

- [GitHub Environments Documentation](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [Deployment Protection Rules](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#deployment-protection-rules)
