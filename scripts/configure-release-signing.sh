#!/usr/bin/env bash
# Validate the Developer ID identity in Keychain and store notarization credentials.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: APPLE_ID=you@example.com DEVELOPER_TEAM_ID=TEAMID \
         ./scripts/configure-release-signing.sh [profile-name]

Validates that Keychain contains a Developer ID Application identity for the
team, then securely prompts for an app-specific password and stores it in a
notarytool Keychain profile. The profile name defaults to everythingmac-notary.

Create and install the Developer ID Application certificate through Apple's
developer portal before running this command. Do not pass the app-specific
password on the command line or save it in an environment variable.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
(( $# <= 1 )) || {
  usage >&2
  exit 2
}

profile_name="${1:-${NOTARY_PROFILE:-everythingmac-notary}}"
apple_id="${APPLE_ID:-}"
team_id="${DEVELOPER_TEAM_ID:-}"

[[ -n "$apple_id" ]] || {
  echo "Set APPLE_ID to the Apple Account used for notarization." >&2
  exit 1
}
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "DEVELOPER_TEAM_ID must be the 10-character Apple Developer Team ID." >&2
  exit 1
}
[[ "$profile_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "The profile name may contain letters, numbers, periods, underscores, and hyphens." >&2
  exit 1
}

identities=()
while IFS= read -r identity; do
  if [[ "$identity" == *"($team_id)" ]]; then
    identities+=("$identity")
  fi
done < <(
  security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p'
)

if (( ${#identities[@]} == 0 )); then
  echo "No valid Developer ID Application identity for team $team_id was found in Keychain." >&2
  echo "Create the certificate with a Keychain Access CSR, then install the downloaded certificate." >&2
  exit 1
fi

echo "Developer ID identity found in Keychain:"
for identity in "${identities[@]}"; do
  echo "  $identity"
done
echo
echo "notarytool will securely prompt for an app-specific password."
echo "It will validate the credentials before saving profile '$profile_name' in Keychain."
xcrun notarytool store-credentials "$profile_name" \
  --apple-id "$apple_id" \
  --team-id "$team_id"

echo
echo "Release signing is configured. Build with:"
echo "  DEVELOPER_TEAM_ID=$team_id NOTARY_PROFILE=$profile_name ./scripts/build-dmg.sh --release"
