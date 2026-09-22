#!/usr/bin/env bash
#
# Build a local Release build of EverythingMac using Developer ID signing,
# matching public releases to keep the signing identity stable.
#
# Why Release (not Debug): the search match-loop is ~100x slower unoptimized
# (~1.5s vs ~14ms per million records). A Debug build feels broken on a
# whole-disk index. Always test with this script, not Xcode's default Debug run.
#
# Set DEVELOPER_ID to choose among Developer ID certificates, or explicitly
# override with LOCAL_SIGN_IDENTITY to use development signing. The Release build uses
# hardened runtime and suppresses Xcode's debug-only get-task-allow entitlement.
#
# Usage: ./scripts/build-dev.sh   →   prints the built .app path.
set -euo pipefail

cd "$(dirname "$0")/../App"

source "../scripts/local-signing.sh"
SIGN_IDENTITY="$(local_signing_identity)"
echo "Signing local build with: $SIGN_IDENTITY"

xcodegen generate
xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
  -configuration Release clean build \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES

# Resolve the real product path from build settings (honors a custom global
# DerivedData location if one is set).
APP="$(xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
        -configuration Release -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/EverythingMac.app"

# Sign every nested executable before resealing the app. The CLI has a distinct
# identity and never inherits the app/indexer's Full Disk Access identifier.
for executable_spec in \
  "EverythingMacIndexingService:com.everythingmac.app" \
  "EverythingMacSearchService:EverythingMacSearchService" \
  "everythingmac:com.everythingmac.cli"; do
  executable_name="${executable_spec%%:*}"
  executable_identifier="${executable_spec#*:}"
  codesign --force --options runtime --timestamp=none \
    --identifier "$executable_identifier" --sign "$SIGN_IDENTITY" \
    "$APP/Contents/MacOS/$executable_name"
done
codesign --force --options runtime --timestamp=none \
  --entitlements EverythingMac.entitlements --identifier com.everythingmac.app \
  --sign "$SIGN_IDENTITY" "$APP"
bash ../scripts/verify-app-signatures.sh "$APP"

# Deploy as a complete bundle so files removed by a newer build cannot survive a
# merge-copy. Stage and verify first, then replace the destination as one rename.
INSTALL_STAGE="$(mktemp -d /Applications/.EverythingMac-install.XXXXXX)"
trap 'rm -rf "$INSTALL_STAGE"' EXIT
ditto "$APP" "$INSTALL_STAGE/EverythingMac.app"
bash ../scripts/verify-app-signatures.sh "$INSTALL_STAGE/EverythingMac.app"
if [[ -e "/Applications/EverythingMac.app" ]]; then
  mv "/Applications/EverythingMac.app" "$INSTALL_STAGE/Previous.app"
fi
if ! mv "$INSTALL_STAGE/EverythingMac.app" "/Applications/EverythingMac.app"; then
  [[ ! -e "$INSTALL_STAGE/Previous.app" ]] || mv "$INSTALL_STAGE/Previous.app" "/Applications/EverythingMac.app"
  exit 1
fi
if ! bash ../scripts/verify-app-signatures.sh "/Applications/EverythingMac.app"; then
  mv "/Applications/EverythingMac.app" "$INSTALL_STAGE/Failed.app" 2>/dev/null || true
  [[ ! -e "$INSTALL_STAGE/Previous.app" ]] || mv "$INSTALL_STAGE/Previous.app" "/Applications/EverythingMac.app"
  echo "Installed bundle failed verification; restored the previous app." >&2
  exit 1
fi

# Registered agents survive UI quits and app replacements. Restart registrations
# that already point at the current executables. A stale registration can make
# kickstart wait indefinitely; launching the UI refreshes it through SMAppService.
for service_spec in \
  "com.everythingmac.indexing-agent:Contents/MacOS/EverythingMacIndexingService" \
  "com.everythingmac.search:Contents/MacOS/EverythingMacSearchService"; do
  service_label="${service_spec%%:*}"
  service_path="${service_spec#*:}"
  service_domain="gui/$(id -u)/${service_label}"
  registered_service="$(launchctl print "$service_domain" 2>/dev/null || true)"
  if grep -Fq "program identifier = ${service_path}" \
      <<<"$registered_service"; then
    launchctl kickstart -k "$service_domain" 2>/dev/null || true
  elif [[ -n "$registered_service" ]]; then
    echo "Skipped stale ${service_label} registration; launch EverythingMac to refresh it."
  fi
done

echo
echo "Built + deployed: /Applications/EverythingMac.app"
echo "Signature:"
codesign -dv "/Applications/EverythingMac.app" 2>&1 \
  | grep -iE "Identifier=|Authority=|TeamIdentifier=|flags=" | sed 's/^/  /'
echo "Background agents with current registrations were restarted."
