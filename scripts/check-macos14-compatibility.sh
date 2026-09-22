#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <derived-data-path>" >&2
  exit 64
fi

derived_data="$1"
app_path="$derived_data/Build/Products/Release/EverythingMac.app"
info_plist="$app_path/Contents/Info.plist"
metadata_path="$app_path/Contents/Resources/Metadata.appintents/extract.actionsdata"
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid"
    wait "$app_pid" || true
  fi
}
trap cleanup EXIT

test -x "$app_path/Contents/MacOS/EverythingMac"
test -f "$metadata_path"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$info_plist")" = "everythingmac"
grep -aq "SearchEverythingMacIntent" "$metadata_path"
grep -aq "EverythingMacShortcuts" "$metadata_path"
grep -aq 'Search ${query}' "$metadata_path"

open -n "$app_path"
for _ in {1..15}; do
  app_pid="$(pgrep -f "$app_path/Contents/MacOS/EverythingMac" | head -n 1 || true)"
  [[ -n "$app_pid" ]] && break
  sleep 1
done

if [[ -z "$app_pid" ]]; then
  echo "EverythingMac did not remain running after launch on macOS 14." >&2
  exit 1
fi

for _ in {1..3}; do
  kill -0 "$app_pid"
  sleep 1
done
