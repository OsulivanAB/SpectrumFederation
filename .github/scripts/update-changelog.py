#!/usr/bin/env python3
"""
Update CHANGELOG.md using GitHub Copilot to analyze recent changes.
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
    
    # Determine which section to use
    if branch_name == "beta" or is_beta:
        section_header = "## [Unreleased - Beta]"
        version_display = version
    else:
        section_header = f"## [{version}] - {current_date}"
        version_display = version
    
    print(f"Using section: {section_header}")

    # Get git diff of recent changes
    try:
        # Get the diff between the previous commit and current
        diff_result = subprocess.run(
            ["git", "diff", "HEAD~1", "HEAD", "--", "SpectrumFederation/"],
            capture_output=True,
            text=True,
            check=True
        )
        git_diff = diff_result.stdout
        
        # Get commit message
        commit_msg = subprocess.run(
            ["git", "log", "-1", "--pretty=%B"],
            capture_output=True,
            text=True,
            check=True
        ).stdout.strip()
        
    except subprocess.CalledProcessError as e:
        print(f"Error getting git diff: {e}")
        git_diff = ""
        commit_msg = ""

    # Truncate diff if too large (keep it reasonable for API)
    max_diff_length = 15000
    if len(git_diff) > max_diff_length:
        git_diff = git_diff[:max_diff_length] + "\n... (diff truncated for API limits)"

    # Read existing CHANGELOG
    changelog_path = Path("CHANGELOG.md")
    existing_changelog = changelog_path.read_text(encoding="utf-8") if changelog_path.exists() else ""

    # Prepare prompt for GitHub Copilot
    current_date = datetime.now().strftime("%Y-%m-%d")
    
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

    # Use GitHub Models API to call Copilot
    import requests

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

    try:
        response = requests.post(api_url, headers=headers, json=payload, timeout=30)
        response.raise_for_status()
        result = response.json()
        new_entry = result["choices"][0]["message"]["content"].strip()
        
        # Clean up any markdown code blocks if present
        new_entry = re.sub(r'^```markdown?\s*', '', new_entry, flags=re.MULTILINE)
        new_entry = re.sub(r'```\s*$', '', new_entry, flags=re.MULTILINE)
        new_entry = new_entry.strip()
        
        print("Generated changelog entry:")
        print(new_entry)
        
    except Exception as e:
        print(f"Error calling GitHub Models API: {e}")
        if hasattr(e, 'response') and hasattr(e.response, 'text'):
            print(f"Response: {e.response.text}")
        # Fallback to basic entry
        new_entry = f"""{section_header}

### Changed
- {commit_msg}
"""
        print("Using fallback changelog entry")

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
        if branch_name == "beta" or is_beta:
            # Look for Unreleased - Beta section
            section_pattern = re.compile(r"^## \[Unreleased - Beta\]")
        else:
            # Look for specific version
            section_pattern = re.compile(r"^## \[" + re.escape(version) + r"\]")
        
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
