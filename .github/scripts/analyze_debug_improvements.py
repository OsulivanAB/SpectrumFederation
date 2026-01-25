#!/usr/bin/env python3
"""
Analyze code changes and suggest debugging improvements.

This script is called by pr-beta-debug-review.yml workflow to:
1. Compare code changes between PR branch and beta
2. Identify areas that would benefit from debugging
3. Use GitHub Copilot API to suggest debugging improvements
4. Apply debug statements to Lua files
"""

import os
import subprocess
import sys
import json
from pathlib import Path
import requests
import re


def get_git_diff(base_ref: str, head_ref: str) -> str:
    """Get git diff between base and head branches for Lua files."""
    try:
        # Get diff of Lua code only (exclude locale files)
        result = subprocess.run(
            ["git", "diff", f"origin/{base_ref}...{head_ref}", "--",
             "SpectrumFederation/**/*.lua",
             ":(exclude)SpectrumFederation/locale/**"],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error getting git diff: {e}")
        return ""


def get_changed_files(base_ref: str, head_ref: str) -> list:
    """Get list of changed Lua files."""
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", f"origin/{base_ref}...{head_ref}", "--",
             "SpectrumFederation/**/*.lua",
             ":(exclude)SpectrumFederation/locale/**"],
            capture_output=True,
            text=True,
            check=True
        )
        return [f.strip() for f in result.stdout.split('\n') if f.strip()]
    except subprocess.CalledProcessError as e:
        print(f"Error getting changed files: {e}")
        return []


def read_file_content(file_path: str) -> str:
    """Read content of a file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            return f.read()
    except Exception as e:
        print(f"Warning: Could not read {file_path}: {e}")
        return ""


def read_debug_system() -> str:
    """Read the debug.lua file to understand the debug system."""
    debug_file = Path("SpectrumFederation/modules/debug.lua")
    if debug_file.exists():
        return debug_file.read_text(encoding="utf-8")
    return ""


def call_copilot_api(prompt: str, github_token: str) -> str:
    """Call GitHub Copilot API to suggest debugging improvements."""
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
                "content": """You are an expert Lua developer and debugging specialist for the SpectrumFederation World of Warcraft addon.

Your task is to analyze code changes and suggest strategic debugging improvements using the SF.Debug system.

Guidelines for debugging suggestions:
1. Add SF.Debug:Info() at key decision points and state changes
2. Add SF.Debug:Warn() for potential error conditions or edge cases
3. Add SF.Debug:Error() in error handling paths
4. Add SF.Debug:Verbose() for detailed execution flow (use sparingly)
5. Use appropriate categories (e.g., "PROFILES", "LOOT_HELPER", "UI", "DATABASE")
6. Include meaningful context in debug messages (variable values, state info)
7. DO NOT add debugging to every line - only where it adds diagnostic value
8. DO NOT add debugging to simple getters/setters
9. DO NOT add debugging to performance-critical loops
10. Focus on: error paths, state changes, user actions, database operations, API calls

Return your response as a JSON object with this structure:
{
  "files": {
    "path/to/file.lua": "full updated file content with debug statements added",
    ...
  },
  "summary": "Brief summary of debugging improvements made"
}

If no debugging improvements are needed, return:
{
  "files": {},
  "summary": "No additional debugging needed"
}"""
            },
            {
                "role": "user",
                "content": prompt
            }
        ],
        "temperature": 0.5,
        "max_tokens": 8000
    }
    
    try:
        response = requests.post(api_url, headers=headers, json=payload, timeout=120)
        response.raise_for_status()
        result = response.json()
        content = result["choices"][0]["message"]["content"]
        
        # Extract JSON from markdown code blocks if present
        json_match = re.search(r'```(?:json)?\s*(\{.*\})\s*```', content, re.DOTALL)
        if json_match:
            return json_match.group(1)
        return content
        
    except requests.exceptions.RequestException as e:
        print(f"Warning: Could not call Copilot API: {e}")
        return None
    except (KeyError, IndexError) as e:
        print(f"Warning: Unexpected API response format: {e}")
        return None


def apply_debug_updates(updates_json: str) -> bool:
    """Apply debugging improvements suggested by Copilot."""
    try:
        updates = json.loads(updates_json)
    except json.JSONDecodeError as e:
        print(f"Error: Could not parse updates JSON: {e}")
        print(f"Raw response: {updates_json[:500]}")
        return False
    
    if not isinstance(updates, dict):
        print("Error: Invalid updates format. Expected dict.")
        return False
    
    files = updates.get("files", {})
    summary = updates.get("summary", "")
    
    print(f"\nDebug Review Summary: {summary}\n")
    
    if not files:
        print("No debugging improvements suggested.")
        return False
    
    any_changes = False
    
    for file_path, new_content in files.items():
        if not new_content or new_content.strip() == "":
            print(f"Skipping empty update for {file_path}")
            continue
        
        full_path = Path(file_path)
        
        if not full_path.exists():
            print(f"Warning: File {file_path} does not exist, skipping")
            continue
        
        # Read existing content to check if there are changes
        existing_content = full_path.read_text(encoding="utf-8")
        
        if existing_content != new_content:
            print(f"Updating {file_path} with debugging improvements")
            full_path.write_text(new_content, encoding="utf-8")
            any_changes = True
        else:
            print(f"No changes needed for {file_path}")
    
    return any_changes


def main():
    """Main execution function."""
    # Get environment variables
    github_token = os.environ.get("GITHUB_TOKEN")
    pr_number = os.environ.get("PR_NUMBER")
    head_ref = os.environ.get("HEAD_REF")
    base_ref = os.environ.get("BASE_REF", "beta")
    
    if not github_token:
        print("Error: GITHUB_TOKEN environment variable not set")
        sys.exit(1)
    
    print(f"Analyzing PR #{pr_number}")
    print(f"Comparing {head_ref} against {base_ref}")
    print("-" * 60)
    
    # Get git diff
    diff = get_git_diff(base_ref, head_ref)
    
    if not diff or diff.strip() == "":
        print("No Lua code changes detected. Skipping debug analysis.")
        return
    
    # Get changed files
    changed_files = get_changed_files(base_ref, head_ref)
    
    if not changed_files:
        print("No changed files detected.")
        return
    
    print(f"Changed files: {', '.join(changed_files)}")
    
    # Read debug system to provide context
    debug_system = read_debug_system()
    
    # Read current content of changed files
    file_contents = {}
    for file_path in changed_files:
        content = read_file_content(file_path)
        if content:
            file_contents[file_path] = content
    
    # Build prompt for Copilot
    prompt = f"""Analyze these code changes and suggest debugging improvements.

## Debug System Available

The addon uses the SF.Debug system defined in debug.lua:

```lua
{debug_system[:2000]}
```

Available methods:
- SF.Debug:Info(category, message, ...) - For key operations
- SF.Debug:Warn(category, message, ...) - For warnings
- SF.Debug:Error(category, message, ...) - For errors
- SF.Debug:Verbose(category, message, ...) - For detailed flow

## Code Changes (git diff)

```diff
{diff[:6000]}
```

## Current File Contents

"""
    
    for file_path, content in list(file_contents.items())[:3]:  # Limit to first 3 files
        prompt += f"\n### {file_path}\n\n```lua\n{content[:3000]}\n```\n"
    
    prompt += """

## Your Task

Review the code changes and suggest strategic debugging improvements. Add SF.Debug statements only where they provide real diagnostic value. Return updated file contents with debugging added.

Remember:
- Focus on error paths, state changes, and user actions
- Use appropriate log levels (Info, Warn, Error, Verbose)
- Use meaningful categories
- Include context in messages (variable values, states)
- Don't over-debug simple code
"""
    
    print("\nCalling GitHub Copilot API for debug analysis...")
    response = call_copilot_api(prompt, github_token)
    
    if not response:
        print("Error: No response from Copilot API")
        sys.exit(1)
    
    print("\nApplying debugging improvements...")
    changes_made = apply_debug_updates(response)
    
    if changes_made:
        print("\n✓ Debugging improvements applied successfully")
    else:
        print("\n✓ No debugging improvements needed")
    
    print("-" * 60)


if __name__ == "__main__":
    main()
