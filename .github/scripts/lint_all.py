#!/usr/bin/env python3
"""
Unified linter for SpectrumFederation CI/CD.

Runs all code quality checks:
- luacheck for Lua files
- yamllint for YAML files
- ruff for Python files
"""

import argparse
import subprocess
import sys
from pathlib import Path


def run_command(cmd, description):
    """Run a command and return success status."""
    print(f"\n[lint] Running {description}...")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False
        )
        
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        
        if result.returncode != 0:
            print(f"[lint] ✗ {description} failed with exit code {result.returncode}")
            return False
        
        print(f"[lint] ✓ {description} passed")
        return True
        
    except FileNotFoundError:
        print(f"[lint] ✗ {description} tool not found")
        return False
    except Exception as e:
        print(f"[lint] ✗ {description} error: {e}")
        return False


def lint_lua(addon_dir):
    """Run luacheck on Lua files."""
    return run_command(
        ["luacheck", addon_dir, "--only", "0"],
        "luacheck (Lua linter)"
    )


def lint_yaml(workflow_dir):
    """Run yamllint on GitHub workflow files."""
    return run_command(
        ["yamllint", "-d", "relaxed", workflow_dir],
        "yamllint (YAML linter)"
    )


def lint_python(ci_scripts_dir):
    """Run ruff on Python files."""
    return run_command(
        ["ruff", "check", ci_scripts_dir],
        "ruff (Python linter)"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Run all linters for SpectrumFederation"
    )
    parser.add_argument(
        "--addon-dir",
        default="SpectrumFederation",
        help="Path to addon directory (default: SpectrumFederation)"
    )
    parser.add_argument(
        "--workflow-dir",
        default=".github/workflows",
        help="Path to GitHub workflows (default: .github/workflows)"
    )
    parser.add_argument(
        "--ci-scripts-dir",
        default=".github/scripts",
        help="Path to CI scripts (default: .github/scripts)"
    )
    parser.add_argument(
        "--skip-lua",
        action="store_true",
        help="Skip Lua linting"
    )
    parser.add_argument(
        "--skip-yaml",
        action="store_true",
        help="Skip YAML linting"
    )
    parser.add_argument(
        "--skip-python",
        action="store_true",
        help="Skip Python linting"
    )
    
    args = parser.parse_args()
    
    # Verify directories exist
    if not args.skip_lua and not Path(args.addon_dir).exists():
        print(f"Error: Addon directory '{args.addon_dir}' not found")
        sys.exit(1)
    
    if not args.skip_yaml and not Path(args.workflow_dir).exists():
        print(f"Error: Workflow directory '{args.workflow_dir}' not found")
        sys.exit(1)
    
    if not args.skip_python and not Path(args.ci_scripts_dir).exists():
        print(f"Error: CI scripts directory '{args.ci_scripts_dir}' not found")
        sys.exit(1)
    
    print("=" * 70)
    print("SpectrumFederation - Unified Linter")
    print("=" * 70)
    
    results = []
    
    # Run linters
    if not args.skip_lua:
        results.append(("Lua", lint_lua(args.addon_dir)))
    
    if not args.skip_yaml:
        results.append(("YAML", lint_yaml(args.workflow_dir)))
    
    if not args.skip_python:
        results.append(("Python", lint_python(args.ci_scripts_dir)))
    
    # Summary
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    
    all_passed = all(result for _, result in results)
    
    for name, passed in results:
        status = "✓ PASSED" if passed else "✗ FAILED"
        print(f"{name:10} {status}")
    
    if all_passed:
        print("\n✓ All linters passed")
        return 0
    else:
        print("\n✗ Some linters failed")
        return 1


if __name__ == "__main__":
    sys.exit(main())
