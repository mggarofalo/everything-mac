#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
identity="${1:-}"
if [[ -z "$identity" ]]; then
  echo "Usage: $0 '<Apple Development signing identity>' ['different-team identity']" >&2
  exit 2
fi

scratch="$(mktemp -d)"
uid="$(id -u)"
search_label="com.everythingmac.trust-probe-search-${uid}-$$"
index_label="com.everythingmac.trust-probe-index-${uid}-$$"
search_service="${search_label}"
index_service="${index_label}"
cleanup() {
  launchctl bootout "gui/${uid}/${search_label}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}/${index_label}" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

swiftc -parse-as-library App/Shared/ConnectionTrust.swift \
  scripts/fixtures/automation-trust/Listener.swift -o "$scratch/listener"
swiftc -parse-as-library scripts/fixtures/automation-trust/Client.swift -o "$scratch/client-base"
codesign --force --sign "$identity" --identifier EverythingMacSearchService \
  --options runtime "$scratch/listener"

sign_client() {
  local name="$1" identifier="$2" signer="$3"
  cp "$scratch/client-base" "$scratch/$name"
  codesign --force --sign "$signer" --identifier "$identifier" --options runtime "$scratch/$name"
}
sign_client app com.everythingmac.app "$identity"
sign_client cli com.everythingmac.cli "$identity"
sign_client other com.everythingmac.other "$identity"
sign_client search-service EverythingMacSearchService "$identity"
cp "$scratch/client-base" "$scratch/adhoc"
codesign --force --sign - --identifier com.everythingmac.cli "$scratch/adhoc"
cp "$scratch/cli" "$scratch/tampered"
printf x >> "$scratch/tampered"

for mode in search index; do
  if [[ "$mode" == search ]]; then
    label="$search_label"
    fixture_mode=search
  else
    label="$index_label"
    fixture_mode=indexer
  fi
  cat > "$scratch/$mode.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array>
<string>${scratch}/listener</string><string>${label}</string><string>${fixture_mode}</string>
</array>
<key>MachServices</key><dict><key>${label}</key><true/></dict>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  launchctl bootstrap "gui/$uid" "$scratch/$mode.plist"
done

expect_accept() {
  local label="$1" client="$2"
  for attempt in 1 2 3 4 5; do
    if "$scratch/$client" "$label"; then
      echo "accepted: $client"
      return
    fi
    sleep 0.2
  done
  echo "Expected accepted peer: $client" >&2
  exit 1
}
expect_reject() {
  local label="$1" client="$2"
  if "$scratch/$client" "$label"; then
    echo "Unexpectedly accepted peer: $client" >&2
    exit 1
  fi
  echo "rejected: $client"
}

expect_accept "$search_service" app
expect_accept "$search_service" cli
expect_reject "$search_service" other
expect_reject "$search_service" adhoc
expect_reject "$search_service" tampered
expect_reject "$index_service" cli
expect_accept "$index_service" search-service

if [[ -n "${NO_TEAM_SIGN_IDENTITY:-}" ]]; then
  sign_client signer-no-team com.everythingmac.cli "$NO_TEAM_SIGN_IDENTITY"
  signer_team="$(codesign -dv --verbose=4 "$scratch/signer-no-team" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [[ "$signer_team" != 'not set' && -n "$signer_team" ]]; then
    echo "NO_TEAM_SIGN_IDENTITY must have no team identifier." >&2
    exit 2
  fi
  expect_reject "$search_service" signer-no-team
fi

if [[ -n "${2:-}" ]]; then
  sign_client other-team com.everythingmac.cli "$2"
  own_team="$(codesign -dv --verbose=4 "$scratch/cli" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  other_team="$(codesign -dv --verbose=4 "$scratch/other-team" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [[ -z "$other_team" || "$other_team" == 'not set' || "$other_team" == "$own_team" ]]; then
    echo "Second identity must have a distinct, nonempty team identifier." >&2
    exit 2
  fi
  expect_reject "$search_service" other-team
else
  echo "Other-team signed probe skipped: no second-team identity supplied."
fi
