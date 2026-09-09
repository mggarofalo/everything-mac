#!/usr/bin/env bash
#
# Build a local Release build of Everything-Mac, signed with a stable Apple
# Development identity so Full Disk Access persists across rebuilds.
#
# Why Release (not Debug): the search match-loop is ~100x slower unoptimized
# (~1.5s vs ~14ms per million records). A Debug build feels broken on a
# whole-disk index. Always test with this script, not Xcode's default Debug run.
#
# Set LOCAL_SIGN_IDENTITY to choose a certificate. Otherwise the script uses the
# first Apple Development identity in the login keychain. The Release build uses
# hardened runtime and suppresses Xcode's debug-only get-task-allow entitlement.
#
# Usage: ./scripts/build-dev.sh   →   prints the built .app path.
set -euo pipefail

cd "$(dirname "$0")/../App"

SIGN_IDENTITY="${LOCAL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' | head -n 1)}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No Apple Development signing identity found." >&2
  echo "Set LOCAL_SIGN_IDENTITY or create a certificate in Xcode Settings > Accounts." >&2
  exit 1
fi

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

codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE="$(codesign -dvv --entitlements - "$APP" 2>&1)"
if ! grep -q 'flags=.*runtime' <<<"$SIGNATURE"; then
  echo "Refusing to install a build without hardened runtime." >&2
  exit 1
fi
if grep -q 'com.apple.security.get-task-allow' <<<"$SIGNATURE"; then
  echo "Refusing to install a build with get-task-allow." >&2
  exit 1
fi
for service_spec in "EverythingMacIndexingService:com.everythingmac.app" \
                    "EverythingMacSearchService:EverythingMacSearchService"; do
  service_name="${service_spec%%:*}"
  expected_identifier="${service_spec#*:}"
  service_signature="$(codesign -dvv "$APP/Contents/MacOS/$service_name" 2>&1)"
  grep -q "Identifier=${expected_identifier}" <<<"$service_signature" || {
    echo "Refusing to install $service_name with an unexpected signing identifier." >&2
    exit 1
  }
  grep -q 'flags=.*runtime' <<<"$service_signature" || {
    echo "Refusing to install $service_name without hardened runtime." >&2
    exit 1
  }
done

# Deploy as a complete bundle so files removed by a newer build cannot survive a
# merge-copy. Stage and verify first, then replace the destination as one rename.
INSTALL_STAGE="$(mktemp -d /Applications/.EverythingMac-install.XXXXXX)"
trap 'rm -rf "$INSTALL_STAGE"' EXIT
ditto "$APP" "$INSTALL_STAGE/EverythingMac.app"
codesign --verify --deep --strict --verbose=2 "$INSTALL_STAGE/EverythingMac.app"
if [[ -e "/Applications/EverythingMac.app" ]]; then
  mv "/Applications/EverythingMac.app" "$INSTALL_STAGE/Previous.app"
fi
if ! mv "$INSTALL_STAGE/EverythingMac.app" "/Applications/EverythingMac.app"; then
  [[ ! -e "$INSTALL_STAGE/Previous.app" ]] || mv "$INSTALL_STAGE/Previous.app" "/Applications/EverythingMac.app"
  exit 1
fi
if ! codesign --verify --deep --strict --verbose=2 "/Applications/EverythingMac.app"; then
  mv "/Applications/EverythingMac.app" "$INSTALL_STAGE/Failed.app" 2>/dev/null || true
  [[ ! -e "$INSTALL_STAGE/Previous.app" ]] || mv "$INSTALL_STAGE/Previous.app" "/Applications/EverythingMac.app"
  echo "Installed bundle failed verification; restored the previous app." >&2
  exit 1
fi

# Registered agents survive UI quits and app replacements. Restart registrations
# that already point at the current executables. A stale registration can make
# kickstart wait indefinitely; launching the UI refreshes it through SMAppService.
for service_spec in "com.everythingmac.indexer:EverythingMacIndexingService" \
                    "com.everythingmac.search:EverythingMacSearchService"; do
  service_label="${service_spec%%:*}"
  service_name="${service_spec#*:}"
  service_domain="gui/$(id -u)/${service_label}"
  registered_service="$(launchctl print "$service_domain" 2>/dev/null || true)"
  if grep -Fq "program identifier = Contents/MacOS/${service_name}" \
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
