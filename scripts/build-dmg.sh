#!/usr/bin/env bash
# Build a functional preview DMG or a signed and notarized public release.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build-dmg.sh [--preview | --release]

  --preview  Sign with an Apple Development identity and skip notarization.
             The app and its services work locally, but Gatekeeper will not
             trust this artifact on another Mac.

  --release  Sign with Developer ID, notarize, staple, and assess the DMG.
             This is the default and requires DEVELOPER_TEAM_ID plus a
             notarytool Keychain profile (NOTARY_PROFILE defaults to
             "everythingmac-notary"). Set DEVELOPER_ID only to disambiguate
             multiple valid identities for the same team.
EOF
}

mode="release"
case "${1:-}" in
  ""|--release) ;;
  --preview) mode="preview" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$repo_dir/App"
build_dir="$app_dir/build"
dist_dir="$repo_dir/dist"
app="$build_dir/Build/Products/Release/EverythingMac.app"
indexing_service="$app/Contents/MacOS/EverythingMacIndexingService"
search_service="$app/Contents/MacOS/EverythingMacSearchService"
cli="$app/Contents/MacOS/everythingmac"

if [[ "$mode" == "preview" ]]; then
  sign_identity="${LOCAL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' | head -n 1)}"
  [[ -n "$sign_identity" ]] || {
    echo "No Apple Development signing identity found." >&2
    echo "Set LOCAL_SIGN_IDENTITY or create a development certificate in Xcode." >&2
    exit 1
  }
  artifact_suffix="-preview"
  timestamp_option=(--timestamp=none)
else
  developer_team_id="${DEVELOPER_TEAM_ID:-}"
  [[ "$developer_team_id" =~ ^[A-Z0-9]{10}$ ]] || {
    echo "DEVELOPER_TEAM_ID must be the 10-character Apple Developer Team ID." >&2
    exit 1
  }

  identities=()
  while IFS= read -r identity; do
    if [[ "$identity" == *"($developer_team_id)" ]]; then
      identities+=("$identity")
    fi
  done < <(
    security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p'
  )

  if [[ -n "${DEVELOPER_ID:-}" ]]; then
    sign_identity="$DEVELOPER_ID"
    [[ "$sign_identity" == "Developer ID Application:"*"($developer_team_id)" ]] || {
      echo "DEVELOPER_ID must be a Developer ID Application identity for team $developer_team_id." >&2
      exit 1
    }
  elif (( ${#identities[@]} == 1 )); then
    sign_identity="${identities[0]}"
  elif (( ${#identities[@]} == 0 )); then
    echo "No valid Developer ID Application identity for team $developer_team_id was found in Keychain." >&2
    echo "Run ./scripts/configure-release-signing.sh after installing the certificate." >&2
    exit 1
  else
    echo "More than one Developer ID Application identity exists for team $developer_team_id." >&2
    echo "Set DEVELOPER_ID to the exact identity to use:" >&2
    printf '  %s\n' "${identities[@]}" >&2
    exit 1
  fi

  notary_profile="${NOTARY_PROFILE:-everythingmac-notary}"
  echo "Validating notarytool Keychain profile '$notary_profile'..."
  xcrun notarytool history --keychain-profile "$notary_profile" --no-progress >/dev/null

  artifact_suffix=""
  timestamp_option=(--timestamp)
fi

security find-identity -v -p codesigning | grep -F "\"$sign_identity\"" >/dev/null || {
  echo "Signing identity not found in the keychain: $sign_identity" >&2
  exit 1
}

cd "$app_dir"
xcodegen generate
xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
  -configuration Release -derivedDataPath "$build_dir" clean build \
  CODE_SIGN_IDENTITY="$sign_identity" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES

[[ -x "$indexing_service" && -x "$search_service" && -x "$cli" ]] || {
  echo "The built app is missing a background service or the command-line tool." >&2
  exit 1
}

# Sign inside out. The explicit identifiers are part of the XPC trust policy.
codesign --force --options runtime "${timestamp_option[@]}" \
  --identifier com.everythingmac.app --sign "$sign_identity" "$indexing_service"
codesign --force --options runtime "${timestamp_option[@]}" \
  --identifier EverythingMacSearchService --sign "$sign_identity" "$search_service"
codesign --force --options runtime "${timestamp_option[@]}" \
  --identifier com.everythingmac.cli --sign "$sign_identity" "$cli"
codesign --force --options runtime "${timestamp_option[@]}" \
  --entitlements "$app_dir/EverythingMac.entitlements" \
  --identifier com.everythingmac.app --sign "$sign_identity" "$app"

bash "$repo_dir/scripts/verify-app-signatures.sh" "$app"
if [[ "$mode" == "release" ]]; then
  signed_team="$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$signed_team" == "$developer_team_id" ]] || {
    echo "Unexpected release signing team: $signed_team" >&2
    exit 1
  }
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
artifact_name="EverythingMac-${version}${artifact_suffix}.dmg"
mkdir -p "$dist_dir"
dmg="$dist_dir/$artifact_name"
checksum="$dmg.sha256"
rm -f "$dmg" "$checksum"

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/everythingmac-dmg.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app" "$stage_dir/EverythingMac.app"
ditto "$repo_dir/LICENSE" "$stage_dir/LICENSE.txt"
ln -s /Applications "$stage_dir/Applications"
hdiutil create -volname "EverythingMac $version" -srcfolder "$stage_dir" \
  -format UDZO -ov "$dmg"
codesign --force "${timestamp_option[@]}" --sign "$sign_identity" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

if [[ "$mode" == "release" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

(
  cd "$dist_dir"
  shasum -a 256 "$artifact_name" > "${artifact_name}.sha256"
)

if [[ "$mode" == "preview" ]]; then
  echo "Built local preview (not notarized): $dmg"
else
  echo "Built signed and notarized release: $dmg"
fi
echo "SHA-256: $checksum"
