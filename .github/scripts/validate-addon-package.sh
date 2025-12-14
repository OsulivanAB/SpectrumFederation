#!/usr/bin/env bash
set -euo pipefail

echo "[validate-addon-package] Starting validation..."

ADDON_NAME="${ADDON_NAME:-SpectrumFederation}"
ADDON_DIR="$ADDON_NAME"

# 1) Check addon directory exists
if [ ! -d "$ADDON_DIR" ]; then
    echo "::error ::Addon directory '$ADDON_DIR' not found at repo root."
    exit 1
fi
echo "[validate-addon-package] Found addon directory: $ADDON_DIR"

# 2) Find the TOC file
TOC_FILE="$ADDON_DIR/${ADDON_NAME}.toc"

if [ ! -f "$TOC_FILE" ]; then
    echo "::error ::TOC file '$TOC_FILE' not found."
    exit 1
fi

echo "[validate-addon-package] Using TOC file: $TOC_FILE"

# 3) Validate TOC name vs folder name
#   TOC filename must start with addon folder name
toc_base="$(basename "$TOC_FILE")"
case "$toc_base" in
    "$ADDON_NAME.toc" | "$ADDON_NAME"_*.toc)
        echo "[validate-addon-package] TOC file name '$toc_base' is valid for folder '$ADDON_NAME'."
        ;;
    *)
        echo "::error ::TOC file '$toc_base' does not start with addon folder name '$ADDON_NAME'."
        echo "        This may fail on CurseForge or in-game."
        exit 1
        ;;
esac

# 4) Check Interface line exists and looks numeric-ish

if ! grep -q '^## Interface:' "$TOC_FILE"; then
    echo "::error ::No '## Interface:' line found in $TOC_FILE."
    exit 1
fi

interface_line="$(grep '^## Interface:' "$TOC_FILE" | head -n1)"
interface_value="${interface_line#*Interface:}"
interface_value="$(echo "$interface_value" | tr -d ' \t\r')"

if [[ ! "$interface_value" =~ ^[0-9]+$ ]]; then
    echo "::error ::Interface value '$interface_value' in $TOC_FILE does not look numeric."
    exit 1
fi

echo "[validate-addon-package] Interface value '$interface_value' looks valid."

# 5) Build test zip
mkdir -p build
ZIP_NAME="${ADDON_NAME}-validation.zip"
rm -f "build/$ZIP_NAME"

echo "[validate-addon-package] Creating test zip: build/$ZIP_NAME"
zip -r "build/$ZIP_NAME" "$ADDON_DIR" > /dev/null

# 6) Validate zip structure for WowUp & CurseForge

# List all entries in the zip and extract their top-level folder names
top_levels="$(unzip -Z1 "build/$ZIP_NAME" | cut -d/ -f1 | sort -u)"

if [ "$top_levels" != "$ADDON_NAME" ]; then
    echo "::error ::Zip top-level entries are '$top_levels', expected only '$ADDON_NAME'."
        echo "        WowUp and CurseForge expect the addon folder at the root of the zip."
    exit 1
fi

# Ensure the TOC file is present in the expected path inside the zip
zip_toc_path="{$ADDON_NAME}/$toc_base"
if ! unzip -Z1 "build/$ZIP_NAME" | grep -q "^$zip_toc_path$"; then
    echo "::error ::TOC file '$zip_toc_path' not found inside zip."
    exit 1
fi

echo "[validate-addon-package] Zip structure looks valid for WowUp and CurseForge."
echo "[validate-addon-package] ✅ Validation successful."