#!/usr/bin/env python3
"""
Analyze code changes and suggest copilot instructions updates.

This script is called by pr-beta-docs-sync.yml workflow to:
1. Compare code changes between PR branch and beta
2. Read existing copilot instructions
3. Use GitHub Copilot API to suggest instruction updates
4. Apply updates to .github/copilot-instructions.md
"""

import os
import subprocess
import sys
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


def get_copilot_instructions_diff(base_ref: str, head_ref: str) -> str:
    """Get git diff of copilot instructions changes already made by user."""
    try:
        result = subprocess.run(
            ["git", "diff", f"origin/{base_ref}...{head_ref}", "--",
             ".github/copilot-instructions.md"],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error getting copilot instructions diff: {e}")
        return ""


def read_copilot_instructions() -> str:
    """Read existing copilot instructions."""
    instructions_path = Path(".github/copilot-instructions.md")
    if instructions_path.exists():
        return instructions_path.read_text(encoding="utf-8")
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
                "content": "You are an expert at maintaining GitHub Copilot instructions for coding projects. Your job is to update instructions based on code changes to keep them accurate and helpful for AI coding agents."
            },
            {
                "role": "user",
                "content": prompt
            }
        ],
        "temperature": 0.7,
        "max_tokens": 8000
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


def apply_instructions_update(new_content: str) -> bool:
    """Apply updated copilot instructions."""
    instructions_path = Path(".github/copilot-instructions.md")
    
    if not new_content or new_content.strip() == "":
        print("No content to update")
        return False
    
    # Read existing content
    existing_content = ""
    if instructions_path.exists():
        existing_content = instructions_path.read_text(encoding="utf-8")
    
    if existing_content == new_content:
        print("No changes needed for copilot instructions")
        return False
    
    print("Updating copilot instructions")
    instructions_path.write_text(new_content, encoding="utf-8")
    return True


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
    
    print(f"Analyzing copilot instructions for PR #{pr_number}")
    print(f"Comparing {head_ref} against {base_ref}")
    
    # Get code diff
    code_diff = get_git_diff(base_ref, head_ref)
    if not code_diff or len(code_diff.strip()) == 0:
        print("No code changes detected")
        return
    
    print(f"Found code changes: {len(code_diff)} characters")
    
    # Get any copilot instructions changes already made by user
    instructions_diff = get_copilot_instructions_diff(base_ref, head_ref)
    if instructions_diff:
        print(f"User has already made some copilot instruction changes: {len(instructions_diff)} characters")
    
    # Read existing instructions
    existing_instructions = read_copilot_instructions()
    
    if not existing_instructions:
        print("No existing copilot instructions found")
        return
    
    print(f"Read existing copilot instructions: {len(existing_instructions)} characters")
    
    # Truncate diff if too large
    max_diff_length = 20000
    if len(code_diff) > max_diff_length:
        code_diff = code_diff[:max_diff_length] + "\n... (diff truncated for API limits)"
    
    # Build prompt for Copilot
    prompt_parts = [
        f"# Copilot Instructions Analysis for PR #{pr_number}",
        "",
        "## Task",
        "Analyze the code changes below and update the GitHub Copilot instructions to keep them accurate and helpful.",
        "",
        "## Code Changes (diff vs beta branch)",
        "```diff",
        code_diff,
        "```",
        "",
    ]
    
    if instructions_diff:
        prompt_parts.extend([
            "## Copilot Instructions Changes Already Made by User",
            "```diff",
            instructions_diff[:5000],  # Truncate if needed
            "```",
            "",
        ])
    
    prompt_parts.extend([
        "## Current Copilot Instructions",
        "```markdown",
        existing_instructions,
        "```",
        "",
        "## Instructions",
        "1. Review the code changes and identify:",
        "   - New files added (update file structure sections)",
        "   - New patterns or conventions introduced",
        "   - Changes to existing patterns",
        "   - New workflows, commands, or tools",
        "   - Deprecated or removed functionality",
        "   - Changes to version numbers, branch models, or release processes",
        "",
        "2. Update the copilot instructions to:",
        "   - Reflect the new file structure if files were added/removed",
        "   - Document new code patterns or conventions",
        "   - Update examples if they reference changed code",
        "   - Remove or update sections about deprecated functionality",
        "   - Keep the same structure and style as the existing instructions",
        "   - Consider the user's existing changes (if any)",
        "",
        "3. IMPORTANT GUIDELINES:",
        "   - Only update sections that are affected by the code changes",
        "   - Maintain the existing markdown structure and formatting",
        "   - Keep the tone consistent with the existing instructions",
        "   - Be specific and practical - these are for AI coding agents",
        "   - Include code examples where appropriate",
        "",
        "## Output Format",
        "Respond with the COMPLETE updated copilot-instructions.md content.",
        "If no updates are needed, respond with exactly: NO_CHANGES_NEEDED",
    ])
    
    prompt = "\n".join(prompt_parts)
    
    print("Calling GitHub Copilot API for instructions analysis...")
    print(f"Prompt size: {len(prompt)} characters")
    
    # Call Copilot API
    response = call_copilot_api(prompt, github_token)
    
    if not response:
        print("No response from Copilot API, skipping copilot instructions updates")
        return
    
    print(f"Received response from Copilot API: {len(response)} characters")
    
    # Check if no changes needed
    if "NO_CHANGES_NEEDED" in response:
        print("Copilot API indicated no changes needed")
        return
    
    # Extract markdown content from response (might be wrapped in code blocks)
    content = response
    if "```markdown" in response:
        start = response.find("```markdown") + 11
        end = response.find("```", start)
        if end > start:
            content = response[start:end].strip()
    elif "```" in response:
        # Try to extract from generic code block
        start = response.find("```") + 3
        end = response.find("```", start)
        if end > start:
            content = response[start:end].strip()
    
    # Apply updates
    any_changes = apply_instructions_update(content)
    
    if any_changes:
        print("Copilot instructions updated successfully")
    else:
        print("No copilot instructions changes needed")


if __name__ == "__main__":
    main()
