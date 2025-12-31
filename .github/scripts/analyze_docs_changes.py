#!/usr/bin/env python3
"""
Analyze code changes and suggest documentation updates.

This script is called by pr-beta-docs-sync.yml workflow to:
1. Compare code changes between PR branch and beta
2. Read existing documentation
3. Use GitHub Copilot API to suggest documentation updates
4. Apply updates to docs/ directory
"""

import os
import subprocess
import sys
import json
from pathlib import Path
import requests


def get_git_diff(base_ref: str, head_ref: str) -> str:
    """Get git diff between base and head branches for code files."""
    try:
        # Get diff of addon code only (exclude docs and workflow files)
        result = subprocess.run(
            ["git", "diff", f"origin/{base_ref}...{head_ref}", "--",
             "SpectrumFederation/",
             "*.toc",
             "*.lua"],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error getting git diff: {e}")
        return ""


def get_docs_diff(base_ref: str, head_ref: str) -> str:
    """Get git diff of documentation changes already made by user."""
    try:
        result = subprocess.run(
            ["git", "diff", f"origin/{base_ref}...{head_ref}", "--",
             "docs/",
             "mkdocs.yml"],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error getting docs diff: {e}")
        return ""


def read_existing_docs() -> dict:
    """Read all existing documentation files."""
    docs_dir = Path("docs")
    doc_files = {}
    
    if not docs_dir.exists():
        return doc_files
    
    for doc_file in docs_dir.rglob("*.md"):
        try:
            relative_path = doc_file.relative_to(docs_dir)
            content = doc_file.read_text(encoding="utf-8")
            doc_files[str(relative_path)] = content
        except Exception as e:
            print(f"Warning: Could not read {doc_file}: {e}")
    
    return doc_files


def read_mkdocs_config() -> str:
    """Read mkdocs.yml configuration."""
    mkdocs_path = Path("mkdocs.yml")
    if mkdocs_path.exists():
        return mkdocs_path.read_text(encoding="utf-8")
    return ""


def call_copilot_api(prompt: str, github_token: str) -> str:
    """Call GitHub Copilot API (via Azure) to analyze changes."""
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
                "content": "You are a technical documentation expert for the SpectrumFederation World of Warcraft addon. Your job is to suggest documentation updates based on code changes. Be thorough but concise. Focus on user-facing changes and developer guidance."
            },
            {
                "role": "user",
                "content": prompt
            }
        ],
        "temperature": 0.7,
        "max_tokens": 4000
    }
    
    try:
        response = requests.post(api_url, headers=headers, json=payload, timeout=60)
        response.raise_for_status()
        result = response.json()
        return result["choices"][0]["message"]["content"]
    except requests.exceptions.RequestException as e:
        print(f"Warning: Could not call Copilot API: {e}")
        return None
    except (KeyError, IndexError) as e:
        print(f"Warning: Unexpected API response format: {e}")
        return None


def apply_doc_updates(updates_json: str) -> bool:
    """Apply documentation updates suggested by Copilot."""
    try:
        updates = json.loads(updates_json)
    except json.JSONDecodeError as e:
        print(f"Error: Could not parse updates JSON: {e}")
        print(f"Raw response: {updates_json[:500]}")
        return False
    
    if not isinstance(updates, dict) or "files" not in updates:
        print("Error: Invalid updates format. Expected dict with 'files' key.")
        return False
    
    any_changes = False
    docs_dir = Path("docs")
    
    for file_path, new_content in updates["files"].items():
        if not new_content or new_content.strip() == "":
            print(f"Skipping empty update for {file_path}")
            continue
            
        full_path = docs_dir / file_path
        
        # Create directory if it doesn't exist
        full_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Read existing content to check if there are changes
        existing_content = ""
        if full_path.exists():
            existing_content = full_path.read_text(encoding="utf-8")
        
        if existing_content != new_content:
            print(f"Updating {file_path}")
            full_path.write_text(new_content, encoding="utf-8")
            any_changes = True
        else:
            print(f"No changes needed for {file_path}")
    
    return any_changes


def main():
    # Get environment variables
    github_token = os.environ.get("GITHUB_TOKEN")
    pr_number = os.environ.get("PR_NUMBER")
    head_ref = os.environ.get("HEAD_REF")
    base_ref = os.environ.get("BASE_REF", "beta")
    
    if not github_token:
        print("Error: GITHUB_TOKEN environment variable not set")
        sys.exit(1)
    
    if not pr_number or not head_ref:
        print("Error: PR_NUMBER and HEAD_REF environment variables must be set")
        sys.exit(1)
    
    print(f"Analyzing documentation changes for PR #{pr_number}")
    print(f"Comparing {head_ref} against {base_ref}")
    
    # Get code diff
    code_diff = get_git_diff(base_ref, head_ref)
    if not code_diff or len(code_diff.strip()) == 0:
        print("No code changes detected")
        return
    
    print(f"Found code changes: {len(code_diff)} characters")
    
    # Get any docs changes already made by user
    docs_diff = get_docs_diff(base_ref, head_ref)
    if docs_diff:
        print(f"User has already made some documentation changes: {len(docs_diff)} characters")
    
    # Read existing documentation
    existing_docs = read_existing_docs()
    mkdocs_config = read_mkdocs_config()
    
    print(f"Read {len(existing_docs)} existing documentation files")
    
    # Truncate diff if too large
    max_diff_length = 20000
    if len(code_diff) > max_diff_length:
        code_diff = code_diff[:max_diff_length] + "\n... (diff truncated for API limits)"
    
    # Build prompt for Copilot
    prompt_parts = [
        f"# Documentation Analysis for PR #{pr_number}",
        "",
        "## Task",
        "Analyze the code changes below and suggest documentation updates for the SpectrumFederation WoW addon.",
        "",
        "## Code Changes (diff vs beta branch)",
        "```diff",
        code_diff,
        "```",
        "",
    ]
    
    if docs_diff:
        prompt_parts.extend([
            "## Documentation Changes Already Made by User",
            "```diff",
            docs_diff[:5000],  # Truncate if needed
            "```",
            "",
        ])
    
    prompt_parts.extend([
        "## Existing Documentation Structure",
        "",
        "### MkDocs Navigation",
        "```yaml",
        mkdocs_config,
        "```",
        "",
        "### Existing Documentation Files",
    ])
    
    for file_path, content in list(existing_docs.items())[:10]:  # Limit to first 10 files
        prompt_parts.extend([
            f"#### {file_path}",
            "```markdown",
            content[:1000] if len(content) > 1000 else content,  # Truncate long files
            "```",
            ""
        ])
    
    prompt_parts.extend([
        "",
        "## Instructions",
        "1. Identify what code changes were made (new features, bug fixes, refactoring, etc.)",
        "2. Determine which documentation files should be updated",
        "3. Consider the user's existing documentation changes (if any)",
        "4. Generate updated documentation content that:",
        "   - Explains new features or changes to users",
        "   - Updates developer documentation if needed",
        "   - Maintains consistency with existing documentation style",
        "   - Includes code examples where appropriate",
        "   - Updates the navigation structure if new files are needed",
        "",
        "## Output Format",
        "Respond with a JSON object containing file updates:",
        "```json",
        "{",
        '  "files": {',
        '    "path/to/file.md": "full updated content of the file",',
        '    "another/file.md": "full updated content"',
        "  }",
        "}",
        "```",
        "",
        "Only include files that need updates. Provide the COMPLETE updated content for each file.",
        "If no documentation updates are needed, respond with: {\"files\": {}}",
    ])
    
    prompt = "\n".join(prompt_parts)
    
    print("Calling GitHub Copilot API for documentation analysis...")
    print(f"Prompt size: {len(prompt)} characters")
    
    # Call Copilot API
    response = call_copilot_api(prompt, github_token)
    
    if not response:
        print("No response from Copilot API, skipping documentation updates")
        return
    
    print(f"Received response from Copilot API: {len(response)} characters")
    
    # Extract JSON from response (might be wrapped in markdown code blocks)
    json_match = response
    if "```json" in response:
        start = response.find("```json") + 7
        end = response.find("```", start)
        if end > start:
            json_match = response[start:end].strip()
    elif "```" in response:
        start = response.find("```") + 3
        end = response.find("```", start)
        if end > start:
            json_match = response[start:end].strip()
    
    # Apply updates
    any_changes = apply_doc_updates(json_match)
    
    if any_changes:
        print("Documentation updates applied successfully")
    else:
        print("No documentation changes needed")


if __name__ == "__main__":
    main()
