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

require_metadata_text() {
  local text="$1"
  if ! grep -aq "$text" "$metadata_path"; then
    echo "App Intents metadata does not contain: $text" >&2
    exit 1
  fi
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
require_metadata_text "SearchEverythingMacIntent"
require_metadata_text 'Search ${query}'
require_metadata_text 'Search in ${applicationName}'
require_metadata_text '"openAppWhenRun":true'

/usr/bin/osascript - "$app_path" <<'APPLESCRIPT'
on run argv
    tell application "Finder"
        open POSIX file (item 1 of argv)
        activate
    end tell
end run
APPLESCRIPT

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
