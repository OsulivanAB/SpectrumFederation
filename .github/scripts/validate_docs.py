#!/usr/bin/env python3
"""
Validate MkDocs documentation.

Runs mkdocs build with --strict flag to catch:
- Build errors
- Broken internal links
- Missing navigation files
- Invalid configuration
- Missing assets
"""

import subprocess
import sys
from pathlib import Path


def main():
    """Run MkDocs build validation."""
    print("[validate-docs] Validating MkDocs documentation...")
    
    # Ensure we're in the repo root
    repo_root = Path(__file__).parent.parent.parent
    
    try:
        result = subprocess.run(
            ["mkdocs", "build", "--clean", "--strict"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=False
        )
        
        # Print output
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        
        if result.returncode == 0:
            print("[validate-docs] ✓ Documentation builds successfully")
            return 0
        else:
            print("::error::MkDocs build failed with errors")
            print("[validate-docs] ✗ Documentation build failed")
            return 1
            
    except FileNotFoundError:
        print("::error::mkdocs command not found. Install with: pip install -r requirements-docs.txt")
        print("[validate-docs] ✗ mkdocs not installed")
        return 1
    except Exception as e:
        print(f"::error::Unexpected error during validation: {e}")
        print(f"[validate-docs] ✗ Validation failed: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
