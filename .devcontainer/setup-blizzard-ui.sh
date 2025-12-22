#!/usr/bin/env bash
set -euo pipefail

echo -e "\033[38;2;0;136;204m[BlizzardUI] Preparing Blizzard UI sources...\033[0m"

# We assume postStartCommand runs in the workspace root
ROOT="$(pwd)"
UI_ROOT="$ROOT/BlizzardUI"

LIVE_DIR="$UI_ROOT/live"
BETA_DIR="$UI_ROOT/beta"
# PTR_DIR="$UI_ROOT/ptr"
# PTR2_DIR="$UI_ROOT/ptr2"
REPO_URL="https://github.com/Gethe/wow-ui-source.git"

mkdir -p "$UI_ROOT"

clone_or_update() {
  local target_dir="$1"
  local branch="$2"

  if [ -d "$target_dir/.git" ]; then
    echo -e "\033[38;2;0;136;204m[BlizzardUI] Updating branch '$branch' in $target_dir\033[0m"
    git -C "$target_dir" fetch origin "$branch" --depth=1
    git -C "$target_dir" checkout "$branch"
    git -C "$target_dir" reset --hard "origin/$branch"
  else
    echo -e "\033[38;2;0;136;204m[BlizzardUI] Cloning branch '$branch' into $target_dir\033[0m"
    rm -rf "$target_dir"
    git clone --depth 1 --branch "$branch" "$REPO_URL" "$target_dir"
  fi
}

clone_or_update "$LIVE_DIR" "live"
clone_or_update "$BETA_DIR" "beta"
# clone_or_update "$PTR_DIR" "ptr"
# clone_or_update "$PTR2_DIR" "ptr2"


echo -e "\033[38;2;0;136;204m[BlizzardUI] Done.\033[0m"