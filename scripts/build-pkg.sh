#!/bin/bash
# Called with an already signed app; create one installer for direct and Sparkle upgrades.
set -euo pipefail
[[ $# -eq 4 ]] || { echo "Usage: $0 <app> <derived-data> <app-identity> <release|preview>" >&2; exit 64; }
app="$1"
build_dir="$2"
app_identity="$3"
mode="$4"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
installer_identity="${DEVELOPER_INSTALLER_ID:-${app_identity/Developer ID Application:/Developer ID Installer:}}"
suffix=""
[[ "$mode" == release ]] || suffix="-preview"
package="$repo_dir/dist/EverythingMac-${version}${suffix}.pkg"
mkdir -p "$repo_dir/dist"
xcodebuild -project "$repo_dir/App/EverythingMac.xcodeproj" -scheme EverythingMacInstaller \
  -configuration Release -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
stage="$(mktemp -d "${TMPDIR:-/tmp}/everythingmac-pkg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/scripts"
ditto "$app" "$stage/scripts/EverythingMac.app"
ditto "$build_dir/Build/Products/Release/EverythingMacInstaller" "$stage/scripts/EverythingMacInstaller"
cp "$repo_dir/scripts/installer/postinstall" "$stage/scripts/postinstall"
chmod 755 "$stage/scripts/postinstall"
codesign --force --options runtime --timestamp --identifier com.everythingmac.installer \
  --sign "$app_identity" "$stage/scripts/EverythingMacInstaller"
# A scripts-only package lets the signed helper stage and atomically exchange the
# complete bundle, including rollback. Installer never merge-copies a running app.
pkgbuild --nopayload --scripts "$stage/scripts" --identifier com.everythingmac.installer \
  --version "$version" "$stage/component.pkg"
cat > "$stage/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>EverythingMac $version</title>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <welcome file="Welcome.html" mime-type="text/html"/>
  <conclusion file="Conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="true" rootVolumeOnly="true"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" visible="false"><pkg-ref id="com.everythingmac.installer"/></choice>
  <pkg-ref id="com.everythingmac.installer" version="$version" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML
mkdir "$stage/resources"
cp "$repo_dir/LICENSE" "$stage/resources/LICENSE.txt"
cat > "$stage/resources/Welcome.html" <<'HTML'
<html><body><h2>Install or update EverythingMac</h2><p>The installer will close EverythingMac and its background services, install the new version, and reopen the app.</p><p>Your index and settings are preserved. You do not need to quit anything manually.</p></body></html>
HTML
cat > "$stage/resources/Conclusion.html" <<'HTML'
<html><body><h2>EverythingMac is installed</h2><p>Open EverythingMac from Applications if it has not reopened. On a first installation, enable EverythingMac in System Settings → Privacy &amp; Security → Full Disk Access.</p><p>For future updates, choose EverythingMac → Check for Updates…</p></body></html>
HTML
package_signing=()
if [[ "$mode" == release || "$installer_identity" == "Developer ID Installer:"* ]]; then
  package_signing=(--sign "$installer_identity" --timestamp)
fi
productbuild --distribution "$stage/Distribution.xml" --package-path "$stage" \
  --resources "$stage/resources" "${package_signing[@]}" "$package"
if (( ${#package_signing[@]} )); then pkgutil --check-signature "$package"; fi
if [[ "$mode" == release ]]; then
  xcrun notarytool submit "$package" --keychain-profile "${NOTARY_PROFILE:-everythingmac-notary}" --wait
  xcrun stapler staple "$package"
  xcrun stapler validate "$package"
  spctl --assess --type install --verbose=2 "$package"
fi
(cd "$repo_dir/dist" && shasum -a 256 "$(basename "$package")" > "$(basename "$package").sha256")
echo "Built installer: $package"
