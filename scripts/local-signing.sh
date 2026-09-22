#!/usr/bin/env bash
# Shared by local installs and preview packaging. Never silently switch from
# distribution signing to development signing: that can change macOS grants.
local_signing_identity() {
  local available candidate_count identity selected_candidate selected_found
  local selected="${LOCAL_SIGN_IDENTITY:-${DEVELOPER_ID:-}}"
  local team="${DEVELOPER_TEAM_ID:-}"
  available="$(security find-identity -v -p codesigning)" || return 1

  if [[ -n "$selected" ]]; then
    if [[ -z "${LOCAL_SIGN_IDENTITY:-}" && "$selected" != "Developer ID Application:"* ]]; then
      echo "DEVELOPER_ID must name a Developer ID Application certificate." >&2
      return 1
    fi
    if [[ -z "${LOCAL_SIGN_IDENTITY:-}" && -n "$team" && "$selected" != *"($team)" ]]; then
      echo "DEVELOPER_ID must belong to DEVELOPER_TEAM_ID $team." >&2
      return 1
    fi
    selected_found=false
    while IFS= read -r identity; do
      if [[ "$identity" == "$selected" ]]; then
        selected_found=true
        break
      fi
    done < <(sed -n 's/.*"\([^"]*\)".*/\1/p' <<<"$available")
    if [[ "$selected_found" != true ]]; then
      echo "Signing identity not found in Keychain: $selected" >&2
      return 1
    fi
    printf '%s\n' "$selected"
    return
  fi

  candidate_count=0
  selected_candidate=''
  while IFS= read -r identity; do
    if [[ "$identity" == "Developer ID Application:"* && ( -z "$team" || "$identity" == *"($team)" ) ]]; then
      candidate_count=$((candidate_count + 1))
      selected_candidate="$identity"
    fi
  done < <(sed -n 's/.*"\([^"]*\)".*/\1/p' <<<"$available")

  if (( candidate_count != 1 )); then
    echo "Expected one valid Developer ID Application identity; found $candidate_count." >&2
    echo "Set DEVELOPER_ID to the exact certificate name (and DEVELOPER_TEAM_ID to filter by team)." >&2
    echo "To explicitly use development signing, set LOCAL_SIGN_IDENTITY to its certificate name." >&2
    return 1
  fi
  printf '%s\n' "$selected_candidate"
}
