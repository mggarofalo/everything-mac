#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "This smoke check launches an app and is limited to disposable GitHub Actions runners." >&2
  exit 64
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <derived-data-path>" >&2
  exit 64
fi

derived_data="$1"
app_path="$derived_data/Build/Products/Release/EverythingMac.app"
info_plist="$app_path/Contents/Info.plist"
metadata_directory="$app_path/Contents/Resources/Metadata.appintents"
metadata_path=""
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid"
    wait "$app_pid" || true
  fi
}
trap cleanup EXIT

has_on_screen_window() {
  /usr/bin/swift - "$app_pid" <<'SWIFT'
import CoreGraphics
import Foundation

let processID = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
let hasWindow = windows.contains { window in
    (window[kCGWindowOwnerPID as String] as? Int) == processID
        && (window[kCGWindowLayer as String] as? Int) == 0
}
exit(hasWindow ? EXIT_SUCCESS : EXIT_FAILURE)
SWIFT
}

test -x "$app_path/Contents/MacOS/EverythingMac"
if [[ ! -d "$metadata_directory" ]]; then
  echo "Missing App Intents metadata directory: $metadata_directory" >&2
  exit 1
fi
metadata_path="$(find "$metadata_directory" -type f -name '*actionsdata' -print -quit)"
if [[ -z "$metadata_path" ]]; then
  echo "No App Intents actions data found under $metadata_directory:" >&2
  find "$metadata_directory" -type f -print >&2
  exit 1
fi
url_scheme="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$info_plist")"
if [[ "$url_scheme" != "everythingmac" ]]; then
  echo "Expected URL scheme everythingmac, found $url_scheme." >&2
  exit 1
fi
if ! jq -e '
  .actions.SearchEverythingMacIntent as $intent
  | $intent.isDiscoverable == true
  and $intent.openAppWhenRun == true
  and $intent.actionConfiguration.actionSummary.wrapper.summaryString.formatString == "Search ${query}"
  and any($intent.parameters[]; .name == "query" and .isOptional == false)
  and any(.autoShortcuts[];
      .actionIdentifier == "SearchEverythingMacIntent"
      and any(.phraseTemplates[]; .key == "Search in ${applicationName}"))
' "$metadata_path" >/dev/null; then
  echo "App Intents metadata is missing a discoverable required-query search action or shortcut." >&2
  exit 1
fi

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

for _ in {1..15}; do
  kill -0 "$app_pid"
  has_on_screen_window && exit 0
  sleep 1
done

echo "EverythingMac did not create an on-screen window after Finder opened it on macOS 14." >&2
exit 1
