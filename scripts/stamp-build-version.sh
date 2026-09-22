#!/usr/bin/env bash
# Xcode runs this on every app build, including incremental and manual builds.
set -euo pipefail

info_plist="$1"
semantic_version="$2"
repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
revision="revision unknown"

if [[ "$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)" == "$repo_dir" ]]; then
  sha="$(git -C "$repo_dir" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    revision="${sha:0:8}"
    if [[ -n "$(git -C "$repo_dir" status --porcelain --untracked-files=normal)" ]]; then
      revision="${revision}-dirty"
    fi
  fi
fi

display_version="${semantic_version} (${revision})"
if /usr/libexec/PlistBuddy -c 'Print :EverythingMacBuildVersion' "$info_plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :EverythingMacBuildVersion $display_version" "$info_plist"
else
  /usr/libexec/PlistBuddy -c "Add :EverythingMacBuildVersion string $display_version" "$info_plist"
fi
