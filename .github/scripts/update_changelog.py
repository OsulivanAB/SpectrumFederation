#!/usr/bin/env python3
"""
Update CHANGELOG.md using GitHub Copilot to analyze recent changes.

This script is called by two workflows:
1. post-merge-beta.yml - Updates beta branch changelog after merge
2. promote-beta-to-main.yml - Updates main branch changelog during promotion

Key behaviors:
- Beta branch: Creates versioned entries like "## [0.2.0-beta.1] - 2025-12-27"
- Main branch: Cleans ALL beta entries from changelog, creates stable version entry
- Backward compatible: Handles legacy "## [Unreleased - Beta]" sections
"""

import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

def main():
    # Get environment variables
    github_token = os.environ.get("GITHUB_TOKEN")
    branch_name = os.environ.get("BRANCH_NAME")
    
    if not github_token:
        print("Error: GITHUB_TOKEN environment variable not set")
        sys.exit(1)
    
    # Read current version from TOC
    toc_path = Path("SpectrumFederation/SpectrumFederation.toc")
    if not toc_path.exists():
        print(f"Error: TOC file not found at {toc_path}")
        sys.exit(1)
        
    toc_content = toc_path.read_text(encoding="utf-8")
    
    version = None
    for line in toc_content.split("\n"):
        if line.strip().startswith("## Version:"):
            version = line.split(":", 1)[1].strip()
            break
    
    if not version:
        print("Error: Could not find version in TOC file")
        sys.exit(1)

    print(f"Current version: {version}")
    
    # Determine if this is a beta version
    is_beta = "-beta" in version
    
    # Get current date for version sections
    current_date = datetime.now().strftime("%Y-%m-%d")
    
    # Determine which section to use
    # CHANGED: Beta now uses actual version number with date instead of "Unreleased - Beta"
    # This prevents confusion and provides proper version tracking in beta changelog
    # Both beta and stable versions now use the same format: "## [version] - date"
    section_header = f"## [{version}] - {current_date}"
    
    print(f"Using section: {section_header}")

    # Get git diff of recent changes
    try:
        # Try to get the merge base for a proper diff
        # First, check if this is a merge commit
        is_merge = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD^2"],
            capture_output=True,
            text=True
        ).returncode == 0
        
        if is_merge:
            # For merge commits, diff against the first parent
            base_commit = "HEAD^1"
            print("Detected merge commit, comparing against first parent")
        else:
            # For regular commits, just compare with previous commit
            base_commit = "HEAD~1"
            # Verify the base commit exists
            verify_result = subprocess.run(
                ["git", "rev-parse", "--verify", base_commit],
                capture_output=True,
                text=True
            )
            if verify_result.returncode != 0:
                print(f"Warning: {base_commit} not available, trying to find merge base")
                # Try to find merge base with main
                merge_base_result = subprocess.run(
                    ["git", "merge-base", "HEAD", "origin/main"],
                    capture_output=True,
                    text=True
                )
                if merge_base_result.returncode == 0:
                    base_commit = merge_base_result.stdout.strip()
                    print(f"Using merge base: {base_commit}")
                else:
                    # Last resort: just get the diff of current commit
                    base_commit = "HEAD^"  # This will fail gracefully below
        
        # Get the diff
        diff_result = subprocess.run(
            ["git", "diff", base_commit, "HEAD", "--", "SpectrumFederation/"],
            capture_output=True,
            text=True,
            check=True
        )
        git_diff = diff_result.stdout
        
        # Get commit message (for merge commits, get the merge message)
        commit_msg = subprocess.run(
            ["git", "log", "-1", "--pretty=%B", "HEAD"],
            capture_output=True,
            text=True,
            check=True
        ).stdout.strip()
        
        print(f"Got git diff ({len(git_diff)} chars) and commit message")
        
    except subprocess.CalledProcessError as e:
        print(f"Error getting git diff: {e}")
        print("Attempting to get diff of just the current commit")
        try:
            # Try to get just the changes in the current commit
            diff_result = subprocess.run(
                ["git", "show", "HEAD", "--", "SpectrumFederation/"],
                capture_output=True,
                text=True,
                check=True
            )
            git_diff = diff_result.stdout
            commit_msg = subprocess.run(
                ["git", "log", "-1", "--pretty=%B"],
                capture_output=True,
                text=True,
                check=True
            ).stdout.strip()
            print(f"Got git show output ({len(git_diff)} chars)")
        except subprocess.CalledProcessError as e2:
            print(f"Error getting git show: {e2}")
            git_diff = ""
            commit_msg = ""

    # Truncate diff if too large (keep it reasonable for API)
    max_diff_length = 15000
    if len(git_diff) > max_diff_length:
        git_diff = git_diff[:max_diff_length] + "\n... (diff truncated for API limits)"

    # Read existing CHANGELOG
    changelog_path = Path("CHANGELOG.md")
    existing_changelog = changelog_path.read_text(encoding="utf-8") if changelog_path.exists() else ""

    # ADDED: Clean beta entries when running on main branch
    # This prevents beta version entries from leaking into the stable changelog
    # Removes entries like:
    #   - "## [0.2.0-beta.1] - 2025-12-27"
    #   - "## [0.1.1-beta.2] - Unreleased"
    #   - "## [Unreleased - Beta]"
    if branch_name == "main" and not is_beta and existing_changelog:
        print("Cleaning beta entries from changelog for main branch...")
        lines = existing_changelog.split("\n")
        cleaned_lines = []
        skip_section = False
        
        for line in lines:
            # Detect start of a beta version section (combined regex for performance)
            if re.match(r"^## \[(?:.*-beta.*|Unreleased - Beta)\]", line):
                skip_section = True
                print(f"  Removing beta section: {line}")
                continue
            
            # Detect start of a new non-beta section (stop skipping)
            if skip_section and line.startswith("## ["):
                skip_section = False
            
            # Keep lines that are not part of beta sections
            if not skip_section:
                cleaned_lines.append(line)
        
        existing_changelog = "\n".join(cleaned_lines)
        print("Beta entries cleaned from changelog")

    # Prepare prompt for GitHub Copilot
    # (current_date already defined earlier in determine_section_header)
    
    prompt_parts = [
        "You are analyzing changes to the SpectrumFederation World of Warcraft addon.",
        "",
        f"Version: {version}",
        f"Branch: {branch_name}",
        f"Commit Message: {commit_msg}",
        "",
        "Git Diff of changes:",
        git_diff,
        "",
        "Based on the commit message and code changes, generate a changelog entry following this format:",
        "",
        section_header,
        "",
        "### Added",
        "- List new features or capabilities added",
        "",
        "### Changed",
        "- List modifications to existing functionality",
        "",
        "### Fixed",
        "- List bug fixes",
        "",
        "### Removed",
        "- List deprecated or removed features",
        "",
        "IMPORTANT RULES:",
        "1. Only include sections that have actual changes (omit empty sections)",
        "2. Be concise but descriptive - focus on user-facing changes",
        "3. Group related changes together",
        "4. Use bullet points starting with capital letters",
        "5. Focus on WHAT changed, not HOW it was implemented",
        "6. If this appears to be a documentation-only or trivial change, generate a minimal entry",
        "7. Do not include changes that are only internal refactoring unless they affect functionality",
        "",
        "Existing changelog for context:",
        existing_changelog[:2000],
        "",
        "Generate ONLY the new changelog entry (the ## section with subsections). Do not include any other text or explanations."
    ]
    
    prompt_text = "\n".join(prompt_parts)

    # Try to use GitHub Models API, but have a robust fallback
    import requests

    new_entry = None
    
    # Only attempt API call if we think we have the right permissions
    # GitHub Actions GITHUB_TOKEN doesn't have models permission by default
    try:
        api_url = "https://models.inference.ai.azure.com/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {github_token}"
        }
        
        payload = {
            "model": "gpt-4o",
            "messages": [
                {
                    "role": "system",
                    "content": "You are a helpful assistant that generates changelog entries for software projects. Be concise and focus on user-facing changes."
                },
                {
                    "role": "user",
                    "content": prompt_text
                }
            ],
            "temperature": 0.3,
            "max_tokens": 1000
        }

        response = requests.post(api_url, headers=headers, json=payload, timeout=30)
        
        # If we get 401, skip to fallback immediately
        if response.status_code == 401:
            print("GitHub Models API not available (missing permissions), using basic changelog generation")
            raise Exception("API not available")
            
        response.raise_for_status()
        result = response.json()
        new_entry = result["choices"][0]["message"]["content"].strip()
        
        # Clean up any markdown code blocks if present
        new_entry = re.sub(r'^```markdown?\s*', '', new_entry, flags=re.MULTILINE)
        new_entry = re.sub(r'```\s*$', '', new_entry, flags=re.MULTILINE)
        new_entry = new_entry.strip()
        
        print("Generated changelog entry using GitHub Models API:")
        print(new_entry)
        
    except Exception as e:
        print(f"Could not use GitHub Models API: {e}")
        if hasattr(e, 'response') and hasattr(e.response, 'text'):
            print(f"Response: {e.response.text}")
        
        # Generate a basic changelog from commit message and file changes
        print("Generating basic changelog from commit analysis...")
        
        # Check if there were any actual addon code changes
        has_code_changes = git_diff and len(git_diff.strip()) > 0
        
        # Parse the diff to identify what changed
        changes = {
            "added": [],
            "changed": [],
            "fixed": [],
            "removed": []
        }
        
        if not has_code_changes:
            # If no addon code changes, this is likely an infrastructure-only change
            changes["changed"].append("Infrastructure and tooling updates (no addon code changes)")
        else:
            # Analyze commit message for keywords
            commit_lower = commit_msg.lower()
            
            # Try to categorize based on commit message
            if any(word in commit_lower for word in ["add", "new", "create", "implement"]):
                changes["added"].append(commit_msg)
            elif any(word in commit_lower for word in ["fix", "bug", "issue", "resolve"]):
                changes["fixed"].append(commit_msg)
            elif any(word in commit_lower for word in ["remove", "delete", "deprecate"]):
                changes["removed"].append(commit_msg)
            else:
                changes["changed"].append(commit_msg)
        
        # Build changelog entry
        entry_parts = [section_header, ""]
        
        if changes["added"]:
            entry_parts.append("### Added")
            for item in changes["added"]:
                entry_parts.append(f"- {item}")
            entry_parts.append("")
        
        if changes["changed"]:
            entry_parts.append("### Changed")
            for item in changes["changed"]:
                entry_parts.append(f"- {item}")
            entry_parts.append("")
        
        if changes["fixed"]:
            entry_parts.append("### Fixed")
            for item in changes["fixed"]:
                entry_parts.append(f"- {item}")
            entry_parts.append("")
        
        if changes["removed"]:
            entry_parts.append("### Removed")
            for item in changes["removed"]:
                entry_parts.append(f"- {item}")
            entry_parts.append("")
        
        new_entry = "\n".join(entry_parts).strip()
        print("Using generated changelog entry")

    # Update CHANGELOG.md
    if existing_changelog:
        # Find where to insert (after the header, before the first version entry)
        lines = existing_changelog.split("\n")
        insert_index = 0
        
        # Skip header lines and find first version entry or Unreleased section
        for i, line in enumerate(lines):
            if line.startswith("## ["):
                insert_index = i
                break
        
        # If no version entries found, append after header
        if insert_index == 0:
            for i, line in enumerate(lines):
                if line.startswith("#") and not line.startswith("##"):
                    insert_index = i + 1
                    break
        
        # Check if this section already exists
        # CHANGED: For beta, match both new format and legacy "Unreleased - Beta" for smooth transition
        if branch_name == "beta" or is_beta:
            # Look for this specific beta version OR old "Unreleased - Beta" section
            # Using f-string for better readability
            section_pattern = re.compile(rf"^## \[({re.escape(version)}|Unreleased - Beta)\]")
        else:
            # Look for specific version
            section_pattern = re.compile(rf"^## \[{re.escape(version)}\]")
        
        section_exists = any(section_pattern.match(line) for line in lines)
        
        if section_exists:
            print(f"Section {section_header} already exists in CHANGELOG. Updating entry...")
            # Find and replace the existing entry
            start_idx = None
            end_idx = None
            
            for i, line in enumerate(lines):
                if section_pattern.match(line):
                    start_idx = i
                elif start_idx is not None and line.startswith("## ["):
                    end_idx = i
                    break
            
            if start_idx is not None:
                if end_idx is None:
                    end_idx = len(lines)
                
                # Replace the section
                new_lines = lines[:start_idx] + [new_entry, ""] + lines[end_idx:]
                new_changelog = "\n".join(new_lines)
            else:
                new_changelog = existing_changelog  # Fallback, shouldn't happen
        else:
            # Insert new entry
            new_lines = (
                lines[:insert_index] +
                ["", new_entry, ""] +
                lines[insert_index:]
            )
            new_changelog = "\n".join(new_lines)
    else:
        # Create new changelog
        new_changelog = f"""# Changelog

All notable changes to SpectrumFederation will be documented in this file.

{new_entry}
"""

    # Write updated changelog
    changelog_path.write_text(new_changelog, encoding="utf-8")
    print(f"\nCHANGELOG.md updated for version {version}")

if __name__ == "__main__":
    main()
