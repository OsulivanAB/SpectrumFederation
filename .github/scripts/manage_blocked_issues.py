#!/usr/bin/env python3
"""
Manage blocked issues in GitHub Projects v2.

This script checks issue relationships and moves issues to the "Blocked" column
if they have unresolved "blocked by" relationships, or moves them to "Todo"
if all blockers are resolved.
"""

import os
import sys
import json
import requests
from typing import Dict, List, Optional


class GitHubProjectManager:
    """Manages GitHub Projects v2 operations."""

    def __init__(self, token: str, repository: str, project_number: int):
        self.token = token
        self.repository = repository
        self.project_number = project_number
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }
        self.graphql_url = "https://api.github.com/graphql"
        
        # Extract owner and repo name
        self.owner, self.repo_name = repository.split("/")
        
        # Cache for project and column information
        self.project_id: Optional[str] = None
        self.column_ids: Dict[str, str] = {}

    def _graphql_query(self, query: str, variables: Optional[Dict] = None) -> Dict:
        """Execute a GraphQL query."""
        payload = {"query": query}
        if variables:
            payload["variables"] = variables
        
        response = requests.post(
            self.graphql_url,
            headers=self.headers,
            json=payload,
            timeout=30
        )
        response.raise_for_status()
        
        data = response.json()
        if "errors" in data:
            print(f"GraphQL errors: {json.dumps(data['errors'], indent=2)}")
            raise Exception(f"GraphQL query failed: {data['errors']}")
        
        return data["data"]

    def get_project_id(self) -> str:
        """Get the project ID for the given project number."""
        if self.project_id:
            return self.project_id
        
        query = """
        query($owner: String!, $number: Int!) {
          user(login: $owner) {
            projectV2(number: $number) {
              id
              title
            }
          }
        }
        """
        
        variables = {
            "owner": self.owner,
            "number": self.project_number
        }
        
        try:
            data = self._graphql_query(query, variables)
            if data.get("user") and data["user"].get("projectV2"):
                self.project_id = data["user"]["projectV2"]["id"]
                print(f"Found project: {data['user']['projectV2']['title']} (ID: {self.project_id})")
                return self.project_id
        except Exception as e:
            print(f"Error getting project ID from user: {e}")
        
        # Try organization if user query fails
        query = """
        query($owner: String!, $number: Int!) {
          organization(login: $owner) {
            projectV2(number: $number) {
              id
              title
            }
          }
        }
        """
        
        try:
            data = self._graphql_query(query, variables)
            if data.get("organization") and data["organization"].get("projectV2"):
                self.project_id = data["organization"]["projectV2"]["id"]
                print(f"Found project: {data['organization']['projectV2']['title']} (ID: {self.project_id})")
                return self.project_id
        except Exception as e:
            print(f"Error getting project ID from organization: {e}")
            raise Exception(f"Could not find project {self.project_number} for owner {self.owner}")

    def get_status_field_and_options(self) -> tuple[str, Dict[str, str]]:
        """Get the Status field ID and its option IDs."""
        project_id = self.get_project_id()
        
        query = """
        query($projectId: ID!) {
          node(id: $projectId) {
            ... on ProjectV2 {
              fields(first: 20) {
                nodes {
                  ... on ProjectV2SingleSelectField {
                    id
                    name
                    options {
                      id
                      name
                    }
                  }
                }
              }
            }
          }
        }
        """
        
        variables = {"projectId": project_id}
        data = self._graphql_query(query, variables)
        
        # Find the Status field
        status_field_id = None
        status_options = {}
        
        if data.get("node") and data["node"].get("fields"):
            for field in data["node"]["fields"]["nodes"]:
                if field and field.get("name") == "Status":
                    status_field_id = field["id"]
                    for option in field.get("options", []):
                        status_options[option["name"]] = option["id"]
                    break
        
        if not status_field_id:
            raise Exception("Could not find Status field in project")
        
        print(f"Status field ID: {status_field_id}")
        print(f"Status options: {list(status_options.keys())}")
        
        return status_field_id, status_options

    def get_issue_project_item(self, issue_number: int) -> Optional[Dict]:
        """Get the project item for an issue."""
        query = """
        query($owner: String!, $repo: String!, $issueNumber: Int!, $projectNumber: Int!) {
          repository(owner: $owner, name: $repo) {
            issue(number: $issueNumber) {
              id
              number
              title
              state
              projectItems(first: 10) {
                nodes {
                  id
                  project {
                    number
                  }
                  fieldValues(first: 20) {
                    nodes {
                      ... on ProjectV2ItemFieldSingleSelectValue {
                        name
                        field {
                          ... on ProjectV2SingleSelectField {
                            name
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        
        variables = {
            "owner": self.owner,
            "repo": self.repo_name,
            "issueNumber": issue_number,
            "projectNumber": self.project_number
        }
        
        data = self._graphql_query(query, variables)
        
        if not data.get("repository") or not data["repository"].get("issue"):
            print(f"Issue #{issue_number} not found")
            return None
        
        issue = data["repository"]["issue"]
        
        # Find the project item for our project
        for item in issue.get("projectItems", {}).get("nodes", []):
            if item and item.get("project", {}).get("number") == self.project_number:
                # Get current status
                current_status = None
                for field_value in item.get("fieldValues", {}).get("nodes", []):
                    if field_value and field_value.get("field", {}).get("name") == "Status":
                        current_status = field_value.get("name")
                        break
                
                return {
                    "item_id": item["id"],
                    "issue_id": issue["id"],
                    "issue_number": issue["number"],
                    "issue_title": issue["title"],
                    "issue_state": issue["state"],
                    "current_status": current_status
                }
        
        print(f"Issue #{issue_number} is not in project {self.project_number}")
        return None

    def get_issue_relationships(self, issue_number: int) -> Dict[str, List[Dict]]:
        """Get issue relationships (blocked by, blocks, etc.)."""
        query = """
        query($owner: String!, $repo: String!, $issueNumber: Int!) {
          repository(owner: $owner, name: $repo) {
            issue(number: $issueNumber) {
              trackedInIssues(first: 20) {
                nodes {
                  number
                  title
                  state
                }
              }
              trackedIssues(first: 20) {
                nodes {
                  number
                  title
                  state
                }
              }
            }
          }
        }
        """
        
        variables = {
            "owner": self.owner,
            "repo": self.repo_name,
            "issueNumber": issue_number
        }
        
        data = self._graphql_query(query, variables)
        
        if not data.get("repository") or not data["repository"].get("issue"):
            return {"blocked_by": [], "blocks": []}
        
        issue = data["repository"]["issue"]
        
        # trackedInIssues = issues that track this one (this issue is tracked by them)
        # In the context of "blocked by", trackedInIssues contains blocking issues
        blocked_by = []
        for tracked_in in issue.get("trackedInIssues", {}).get("nodes", []) or []:
            if tracked_in:
                blocked_by.append({
                    "number": tracked_in["number"],
                    "title": tracked_in["title"],
                    "state": tracked_in["state"]
                })
        
        # trackedIssues = issues that this one tracks (issues blocked by this one)
        blocks = []
        for tracked in issue.get("trackedIssues", {}).get("nodes", []) or []:
            if tracked:
                blocks.append({
                    "number": tracked["number"],
                    "title": tracked["title"],
                    "state": tracked["state"]
                })
        
        return {
            "blocked_by": blocked_by,
            "blocks": blocks
        }

    def update_issue_status(self, item_id: str, status_field_id: str, status_option_id: str) -> bool:
        """Update the status of a project item."""
        mutation = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
          updateProjectV2ItemFieldValue(
            input: {
              projectId: $projectId
              itemId: $itemId
              fieldId: $fieldId
              value: $value
            }
          ) {
            projectV2Item {
              id
            }
          }
        }
        """
        
        variables = {
            "projectId": self.get_project_id(),
            "itemId": item_id,
            "fieldId": status_field_id,
            "value": {
                "singleSelectOptionId": status_option_id
            }
        }
        
        try:
            self._graphql_query(mutation, variables)
            return True
        except Exception as e:
            print(f"Error updating status: {e}")
            return False

    def process_issue(self, issue_number: int) -> None:
        """Process a single issue and update its blocked status."""
        print(f"\n{'='*60}")
        print(f"Processing issue #{issue_number}")
        print(f"{'='*60}")
        
        # Get project item info
        project_item = self.get_issue_project_item(issue_number)
        if not project_item:
            print(f"Skipping issue #{issue_number} - not in project")
            return
        
        issue_state = project_item["issue_state"]
        current_status = project_item["current_status"]
        
        print(f"Issue: #{issue_number} - {project_item['issue_title']}")
        print(f"State: {issue_state}")
        print(f"Current Status: {current_status}")
        
        # Don't process closed issues
        if issue_state == "CLOSED":
            print("Issue is closed, skipping")
            return
        
        # Get relationships
        relationships = self.get_issue_relationships(issue_number)
        blocked_by = relationships["blocked_by"]
        
        print(f"Blocked by: {len(blocked_by)} issue(s)")
        
        # Check if there are any unresolved blocking issues
        unresolved_blockers = [
            blocker for blocker in blocked_by
            if blocker["state"] != "CLOSED"
        ]
        
        if unresolved_blockers:
            print(f"Found {len(unresolved_blockers)} unresolved blocker(s):")
            for blocker in unresolved_blockers:
                print(f"  - #{blocker['number']}: {blocker['title']} ({blocker['state']})")
        
        # Get status field and options
        status_field_id, status_options = self.get_status_field_and_options()
        
        # Determine the target status
        if unresolved_blockers:
            target_status = "Blocked"
            target_reason = f"has {len(unresolved_blockers)} unresolved blocker(s)"
        else:
            if blocked_by:
                # Had blockers but all are resolved
                target_status = "Todo"
                target_reason = "all blockers are resolved"
            else:
                # No blockers at all
                if current_status == "Blocked":
                    target_status = "Todo"
                    target_reason = "no longer has blockers"
                else:
                    print("No blockers and not in Blocked status, no change needed")
                    return
        
        # Check if status needs to change
        if current_status == target_status:
            print(f"Issue is already in '{target_status}' status, no change needed")
            return
        
        # Verify target status exists
        if target_status not in status_options:
            print(f"Warning: '{target_status}' status not found in project")
            print(f"Available statuses: {list(status_options.keys())}")
            return
        
        # Update the status
        print(f"Moving issue to '{target_status}' status ({target_reason})")
        success = self.update_issue_status(
            project_item["item_id"],
            status_field_id,
            status_options[target_status]
        )
        
        if success:
            print(f"✓ Successfully moved issue #{issue_number} to '{target_status}'")
        else:
            print(f"✗ Failed to move issue #{issue_number}")

    def get_all_project_issues(self) -> List[int]:
        """Get all open issues in the project."""
        query = """
        query($projectId: ID!, $cursor: String) {
          node(id: $projectId) {
            ... on ProjectV2 {
              items(first: 50, after: $cursor) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  content {
                    ... on Issue {
                      number
                      state
                    }
                  }
                }
              }
            }
          }
        }
        """
        
        project_id = self.get_project_id()
        issue_numbers = []
        cursor = None
        
        while True:
            variables = {"projectId": project_id, "cursor": cursor}
            data = self._graphql_query(query, variables)
            
            items = data.get("node", {}).get("items", {})
            for item in items.get("nodes", []):
                content = item.get("content")
                if content and content.get("state") == "OPEN":
                    issue_numbers.append(content["number"])
            
            page_info = items.get("pageInfo", {})
            if not page_info.get("hasNextPage"):
                break
            cursor = page_info.get("endCursor")
        
        return issue_numbers


def main():
    """Main entry point."""
    # Get environment variables
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        print("Error: GITHUB_TOKEN environment variable is required")
        sys.exit(1)
    
    repository = os.environ.get("REPOSITORY")
    if not repository:
        print("Error: REPOSITORY environment variable is required")
        sys.exit(1)
    
    project_number = int(os.environ.get("PROJECT_NUMBER", "1"))
    issue_number = os.environ.get("ISSUE_NUMBER")
    check_single = os.environ.get("CHECK_SINGLE", "false").lower() == "true"
    
    print(f"Repository: {repository}")
    print(f"Project Number: {project_number}")
    
    # Initialize manager
    manager = GitHubProjectManager(token, repository, project_number)
    
    # Process issues
    if check_single and issue_number:
        # Process single issue
        print(f"Processing single issue: #{issue_number}")
        manager.process_issue(int(issue_number))
    else:
        # Process all open issues in the project
        print("Processing all open issues in the project")
        issue_numbers = manager.get_all_project_issues()
        print(f"Found {len(issue_numbers)} open issue(s) in project")
        
        for issue_num in issue_numbers:
            try:
                manager.process_issue(issue_num)
            except Exception as e:
                print(f"Error processing issue #{issue_num}: {e}")
                continue
    
    print("\n" + "="*60)
    print("Blocked issue management complete")
    print("="*60)


if __name__ == "__main__":
    main()
