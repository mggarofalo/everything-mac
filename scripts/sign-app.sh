#!/bin/bash
# One signing order for local installs and public releases, including Sparkle's helpers.
set -euo pipefail
[[ $# -eq 3 ]] || { echo "Usage: $0 <app> <identity> <timestamp|none>" >&2; exit 64; }
app="$1"
identity="$2"
timestamp="$3"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$timestamp" == timestamp ]]; then
  timestamp_option=(--timestamp)
else
  timestamp_option=(--timestamp=none)
fi
framework="$app/Contents/Frameworks/Sparkle.framework"
for component in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
  item="$framework/Versions/B/$component"
  [[ -e "$item" ]] || { echo "Missing Sparkle component: $component" >&2; exit 1; }
  codesign --force --options runtime "${timestamp_option[@]}" \
    --preserve-metadata=identifier,entitlements --sign "$identity" "$item"
done
codesign --force --options runtime "${timestamp_option[@]}" --sign "$identity" "$framework"
for specification in \
  'EverythingMacIndexingService:com.everythingmac.app' \
  'EverythingMacSearchService:EverythingMacSearchService' \
  'everythingmac:com.everythingmac.cli'; do
  codesign --force --options runtime "${timestamp_option[@]}" \
    --identifier "${specification#*:}" --sign "$identity" "$app/Contents/MacOS/${specification%%:*}"
done
codesign --force --options runtime "${timestamp_option[@]}" \
  --entitlements "$repo_dir/App/EverythingMac.entitlements" \
  --identifier com.everythingmac.app --sign "$identity" "$app"
bash "$repo_dir/scripts/verify-app-signatures.sh" "$app"
