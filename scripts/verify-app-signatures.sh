#!/usr/bin/env bash
# Verify every executable in the application against the XPC trust contract.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: $0 <EverythingMac.app>" >&2; exit 64; }
app="$1"
app_team="$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ -n "$app_team" && "$app_team" != not\ set ]] || {
  echo "The app must have a signing team." >&2
  exit 1
}

for specification in \
  '.:com.everythingmac.app' \
  'Contents/MacOS/EverythingMacIndexingService:com.everythingmac.app' \
  'Contents/MacOS/EverythingMacSearchService:EverythingMacSearchService' \
  'Contents/MacOS/everythingmac:com.everythingmac.cli'; do
  relative_path="${specification%%:*}"
  expected_identifier="${specification#*:}"
  item="$app/$relative_path"
  [[ -e "$item" ]] || { echo "Missing signed component: $relative_path" >&2; exit 1; }
  codesign --verify --strict --verbose=2 "$item"
  signature="$(codesign -dvv --entitlements - "$item" 2>&1)"
  grep -Fxq "Identifier=$expected_identifier" <<<"$signature" || {
    echo "Unexpected signing identifier: $relative_path" >&2
    exit 1
  }
  grep -Fxq "TeamIdentifier=$app_team" <<<"$signature" || {
    echo "Unexpected signing team: $relative_path" >&2
    exit 1
  }
  grep -q 'flags=.*runtime' <<<"$signature" || {
    echo "Missing hardened runtime: $relative_path" >&2
    exit 1
  }
  if grep -q 'com.apple.security.get-task-allow' <<<"$signature"; then
    echo "Unexpected get-task-allow entitlement: $relative_path" >&2
    exit 1
  fi
done
