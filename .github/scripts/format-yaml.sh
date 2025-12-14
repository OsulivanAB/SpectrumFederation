#!/usr/bin/env bash
#
# Format YAML files in .github/ using yamlfmt
#

set -euo pipefail

cd "$(dirname "$0")/../.."

echo "Formatting YAML files in .github/..."
find .github -name "*.yml" -exec yamlfmt -w {} \;

echo "✓ Done! Run 'yamllint -d relaxed .github/' to check for remaining issues."
