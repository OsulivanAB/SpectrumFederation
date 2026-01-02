# Manage Blocked Issues Workflow

## Overview

This workflow automatically manages the status of issues in GitHub Projects v2 based on their blocking relationships. When an issue has unresolved "blocked by" relationships, it's automatically moved to the "Blocked" column. When all blockers are resolved, it's moved back to "Todo".

## Files Created

1. **`.github/workflows/manage-blocked-issues.yml`** - GitHub Actions workflow
2. **`.github/scripts/manage_blocked_issues.py`** - Python script that handles the logic

## How It Works

### Triggers

The workflow runs in three scenarios:

1. **Issue Events**: When issues are opened, edited, closed, reopened, or deleted
2. **Schedule**: Every 30 minutes to catch any missed relationship changes
3. **Manual**: Via workflow_dispatch in the GitHub Actions UI

### Logic

For each issue processed:

1. Check if the issue is in GitHub Project #1 ("Spectrum Federation Addon")
2. Skip if the issue is closed
3. Query the issue's relationships using GitHub's GraphQL API
4. Check for "blocked by" relationships where the blocking issue is still open
5. If unresolved blockers exist:
   - Move issue to "Blocked" status (if not already there)
6. If no unresolved blockers:
   - If currently in "Blocked" status, move to "Todo"
   - Otherwise, no change needed

### GitHub API Usage

The script uses GitHub's GraphQL API to:

- Query project information
- Get issue relationships (trackedInIssues for "blocked by")
- Get current project item status
- Update project item status field

### Requirements

- **GitHub Token**: Workflow uses `GITHUB_TOKEN` with `issues: write` permission
- **Project**: Issues must be in Project #1
- **Status Field**: Project must have a "Status" field with "Blocked" and "Todo" options
- **Relationships**: Uses GitHub's native issue relationships feature

## Testing

### Manual Testing

You can test the workflow manually:

1. Go to **Actions** → **Manage Blocked Issues**
2. Click **Run workflow**
3. Optional: Enter a specific issue number to test
4. Click **Run workflow**

### Testing Scenarios

#### Scenario 1: Issue with Open Blocker

1. Create Issue A
2. Create Issue B
3. In Issue A, add relationship: "blocked by #B"
4. Run workflow
5. **Expected**: Issue A moves to "Blocked" column

#### Scenario 2: Blocker is Resolved

1. Close Issue B
2. Run workflow
3. **Expected**: Issue A moves to "Todo" column

#### Scenario 3: No Blockers

1. Create Issue C with no relationships
2. Run workflow
3. **Expected**: Issue C stays in current status

### Viewing Logs

To see what the workflow did:

1. Go to **Actions** → **Manage Blocked Issues**
2. Click on a workflow run
3. Click on the "Update blocked status" job
4. Expand the "Update blocked status" step to see detailed logs

The script outputs:
- Which issues it's processing
- Current status of each issue
- Blocking relationships found
- Whether status was changed

## Customization

### Changing Target Statuses

To change which statuses issues move between, edit the script:

```python
# In process_issue() method, around line 330
if unresolved_blockers:
    target_status = "Blocked"  # Change this
else:
    target_status = "Todo"     # Change this
```

### Changing Schedule

To change how often the workflow runs automatically:

```yaml
# In .github/workflows/manage-blocked-issues.yml
schedule:
  - cron: '*/30 * * * *'  # Currently every 30 minutes
```

### Changing Project Number

To use a different project:

```yaml
# In .github/workflows/manage-blocked-issues.yml
env:
  PROJECT_NUMBER: 1  # Change this to your project number
```

## Troubleshooting

### Workflow Doesn't Run

**Issue**: Workflow doesn't trigger on issue events

**Solution**: 
- Check that the workflow file is in the default branch (main or beta)
- Verify the issue is in the repository (not a different repo)

### Script Fails with "Project Not Found"

**Issue**: Cannot find project with specified number

**Solution**:
- Verify PROJECT_NUMBER is correct
- Check if project belongs to user or organization
- Ensure GITHUB_TOKEN has access to the project

### Script Fails with "Status Field Not Found"

**Issue**: Project doesn't have expected Status field

**Solution**:
- Open the project in GitHub
- Verify there's a "Status" field (case-sensitive)
- Check that "Blocked" and "Todo" options exist

### Issues Not Moving

**Issue**: Script runs but doesn't change issue status

**Solution**:
- Check if issue is actually in the project
- Verify relationships are set correctly (use "blocked by" not "blocks")
- Check workflow logs for detailed error messages
- Ensure issue isn't closed (closed issues are skipped)

### Rate Limiting

**Issue**: Script fails with rate limit errors

**Solution**:
- The workflow uses authenticated requests which have higher limits
- If running very frequently, consider increasing the schedule interval
- GitHub Actions have generous rate limits, so this is unlikely

## GitHub Relationships

GitHub supports several relationship types. This workflow specifically looks for:

- **blocked by**: Issue A is blocked by Issue B
  - In GraphQL: Issue A's `trackedInIssues` contains Issue B
  - This means Issue A cannot proceed until Issue B is resolved

The inverse relationship is "blocks":
- **blocks**: Issue B blocks Issue A
  - In GraphQL: Issue B's `trackedIssues` contains Issue A
  - The workflow doesn't need to check this explicitly

## Performance

The script is designed to be efficient:

- Uses GraphQL to minimize API calls
- Caches project information between issues
- Only updates status when needed (checks current status first)
- Processes issues in batches when run on schedule

### API Calls Per Run

For a single issue:
- 1 call to get project ID
- 1 call to get status field options
- 1 call to get issue project item
- 1 call to get issue relationships
- 1 call to update status (if needed)

**Total: ~5 API calls per issue**

For all issues (scheduled run):
- 1 call to get project ID
- 1 call to get status field options
- 1 call to list all project issues
- 5 calls per open issue in project

## Future Enhancements

Potential improvements:

1. **Support Multiple Projects**: Process issues across multiple projects
2. **Custom Status Mappings**: Configure which statuses to use via workflow inputs
3. **Notifications**: Send Discord/Slack notifications when issues are blocked
4. **Batch Updates**: Update multiple issues in a single GraphQL mutation
5. **Dry Run Mode**: Test changes without actually moving issues
6. **Priority Handling**: Prioritize high-priority blocked issues

## References

- [GitHub GraphQL API Documentation](https://docs.github.com/en/graphql)
- [GitHub Projects v2 API](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Issue Relationships](https://docs.github.com/en/issues/tracking-your-work-with-issues/about-issues#issue-relationships)
