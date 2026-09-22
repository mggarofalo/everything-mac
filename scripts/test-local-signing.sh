#!/usr/bin/env bash
# Exercise local identity selection without reading the developer's Keychain.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_dir/scripts/local-signing.sh"

security() {
  printf '%s\n' "$fake_security_output"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_identity() {
  local expected="$1"
  local actual
  actual="$(local_signing_identity)" || fail "expected $expected to be selected"
  [[ "$actual" == "$expected" ]] || fail "expected $expected, got $actual"
}

expect_failure() {
  local exit_code
  set +e
  local_signing_identity >/dev/null 2>&1
  exit_code=$?
  set -e
  (( exit_code != 0 )) || fail "expected identity selection to fail"
}

reset_selection() {
  unset LOCAL_SIGN_IDENTITY DEVELOPER_ID DEVELOPER_TEAM_ID
}

team_a='Developer ID Application: Example One (ABCDE12345)'
team_b='Developer ID Application: Example Two (FGHIJ67890)'
development='Apple Development: Example Developer (ABCDE12345)'

reset_selection
fake_security_output="  1) ABCDEF0123456789 \"$team_a\""$'\n     1 valid identities found'
expect_identity "$team_a"

reset_selection
fake_security_output='     0 valid identities found'
expect_failure

reset_selection
fake_security_output="  1) ABCDEF0123456789 \"$team_a\""$'\n'"  2) 1234567890ABCDEF \"$team_b\""$'\n     2 valid identities found'
expect_failure

reset_selection
DEVELOPER_TEAM_ID='FGHIJ67890'
expect_identity "$team_b"

reset_selection
DEVELOPER_ID="$team_b"
expect_identity "$team_b"

reset_selection
fake_security_output="  1) FEDCBA9876543210 \"$development\""$'\n     1 valid identities found'
LOCAL_SIGN_IDENTITY="$development"
expect_identity "$development"

echo 'local signing identity selection tests passed'
