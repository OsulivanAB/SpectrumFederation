#!/usr/bin/env python3
"""
Clean up merged feature branch after successful release.

Finds the PR associated with a commit and deletes the source branch.
"""

import argparse
import os
import sys


def cleanup_merged_branch(commit_sha, repo):
    """Delete the branch that was merged in a PR."""
    try:
        import requests
    except ImportError:
        print("Error: requests library not available")
        print("Install with: pip install requests")
        sys.exit(1)
    
    github_token = os.environ.get("GITHUB_TOKEN")
    if not github_token:
        print("Error: GITHUB_TOKEN not set")
        sys.exit(1)
    
    headers = {
        "Authorization": f"Bearer {github_token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
    }
    
    print(f"[cleanup] Looking for PR associated with commit {commit_sha[:7]}")
    
    # Find PR for this commit
    try:
        url = f"https://api.github.com/repos/{repo}/commits/{commit_sha}/pulls"
        response = requests.get(url, headers=headers, timeout=30)
        response.raise_for_status()
        pulls = response.json()
        
        if not pulls:
            print("[cleanup] No PR found for this commit, skipping branch cleanup")
            return 0
        
        pr_number = pulls[0]["number"]
        print(f"[cleanup] Found PR #{pr_number}")
        
    except requests.RequestException as e:
        print(f"Warning: Failed to find PR for commit: {e}")
        return 0
    
    # Get PR details to find head branch
    try:
        url = f"https://api.github.com/repos/{repo}/pulls/{pr_number}"
        response = requests.get(url, headers=headers, timeout=30)
        response.raise_for_status()
        pr_data = response.json()
        
        head_branch = pr_data["head"]["ref"]
        
        # Safety checks
        if not head_branch:
            print("[cleanup] No head branch found in PR")
            return 0
        
        if head_branch in ["beta", "main"]:
            print(f"[cleanup] Branch '{head_branch}' is protected, skipping deletion")
            return 0
        
        print(f"[cleanup] Target branch for deletion: {head_branch}")
        
    except requests.RequestException as e:
        print(f"Warning: Failed to get PR details: {e}")
        return 0
    
    # Delete the branch
    try:
        url = f"https://api.github.com/repos/{repo}/git/refs/heads/{head_branch}"
        response = requests.delete(url, headers=headers, timeout=30)
        
        if response.status_code == 204:
            print(f"[cleanup] ✓ Branch '{head_branch}' deleted successfully")
            return 0
        elif response.status_code == 404:
            print(f"[cleanup] Branch '{head_branch}' already deleted")
            return 0
        elif response.status_code == 422:
            print(f"[cleanup] Branch '{head_branch}' is protected or cannot be deleted")
            return 0
        else:
            print(f"Warning: Unexpected response when deleting branch: {response.status_code}")
            print(f"Response: {response.text}")
            return 0
            
    except requests.RequestException as e:
        print(f"Warning: Failed to delete branch: {e}")
        return 0


def main():
    parser = argparse.ArgumentParser(
        description="Clean up merged feature branch"
    )
    parser.add_argument(
        "commit_sha",
        help="Commit SHA that was merged"
    )
    parser.add_argument(
        "--repo",
        default="OsulivanAB/SpectrumFederation",
        help="GitHub repository (default: OsulivanAB/SpectrumFederation)"
    )
    
    args = parser.parse_args()
    
    return cleanup_merged_branch(args.commit_sha, args.repo)


if __name__ == "__main__":
    sys.exit(main())
