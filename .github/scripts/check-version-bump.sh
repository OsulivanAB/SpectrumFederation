#!/usr/bin/env bash
set -euo pipefail

echo "[check-version-bump] Checking addon version bump..."

ADDON_NAME="${ADDON_NAME:-SpectrumFederation}"
BASE_REF="${BASE_REF:-}"

if [ -z "$BASE_REF" ]; then
  echo "[check-version-bump] BASE_REF not set, assuming non-PR run. Skipping."
  exit 0
fi

TOC_FILE="${ADDON_NAME}/${ADDON_NAME}.toc"

if [ ! -f "$TOC_FILE" ]; then
  echo "::error ::TOC file '$TOC_FILE' not found in PR branch."
  exit 1
fi

# Helper to extract '## Version: ...' from a toc blob
extract_version() {
  grep -E '^## Version:' | head -n1 | sed 's/^## Version://i' | xargs || true
}

# Current branch version (PR head)
current_version_line="$(grep -E '^## Version:' "$TOC_FILE" || true)"
if [ -z "$current_version_line" ]; then
  echo "::error ::No '## Version:' line found in $TOC_FILE on PR branch."
  exit 1
fi
current_version="$(printf '%s\n' "$current_version_line" | extract_version)"

# Base branch version (origin/$BASE_REF)
base_toc_blob="$(git show "origin/$BASE_REF:$TOC_FILE" 2>/dev/null || true)"
if [ -z "$base_toc_blob" ]; then
  echo "[check-version-bump] No TOC file in base branch origin/$BASE_REF, probably first release. Skipping version bump check."
  exit 0
fi

base_version_line="$(printf '%s\n' "$base_toc_blob" | grep -E '^## Version:' | head -n1 || true)"
if [ -z "$base_version_line" ]; then
  echo "[check-version-bump] No '## Version:' in base branch TOC, skipping version bump check."
  exit 0
fi
base_version="$(printf '%s\n' "$base_version_line" | extract_version)"

echo "[check-version-bump] Base ($BASE_REF) addon version : $base_version"
echo "[check-version-bump] PR branch addon version        : $current_version"

if [ "$current_version" = "$base_version" ]; then
  echo "::error ::Addon '## Version:' in $TOC_FILE is still '$current_version'."
  echo "          When merging into '$BASE_REF', bump the addon version (e.g. 0.0.2 or 0.0.2-beta.1)."
  echo "          This is different from the game interface version (## Interface: $interface_value)."
  exit 1
fi

echo "[check-version-bump] ✅ Addon version has been bumped."