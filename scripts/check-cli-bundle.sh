#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <EverythingMac.app>" >&2
  exit 2
fi

app="$1"
info="$app/Contents/Info.plist"
gui_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
gui="$app/Contents/MacOS/$gui_name"
cli="$app/Contents/MacOS/everythingmac"

[[ "$gui_name" == 'EverythingMacApp' ]] || {
  echo "Unexpected CFBundleExecutable: $gui_name" >&2
  exit 1
}
[[ -f "$gui" && -x "$gui" && -f "$cli" && -x "$cli" ]] || {
  echo "The app must contain distinct executable GUI and CLI files." >&2
  exit 1
}
gui_inode="$(stat -f '%d:%i' "$gui")"
cli_inode="$(stat -f '%d:%i' "$cli")"
[[ "$gui_inode" != "$cli_inode" ]] || {
  echo "GUI and CLI resolve to the same executable inode." >&2
  exit 1
}

echo "Verified GUI ($gui_name) and CLI (everythingmac) are distinct executables."
