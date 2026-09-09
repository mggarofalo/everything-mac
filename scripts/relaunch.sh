#!/usr/bin/env bash
#
# Quit the UI, drop the cache, restart both services, and force a fresh scan.
# Run this AFTER granting Full Disk Access so the first scan can see every
# volume (without FDA, macOS hides the Data volume's firmlinks from the scan and
# you only get System-volume files).
set -euo pipefail

pkill -x EverythingMac 2>/dev/null || true
sleep 1

CACHE="$HOME/Library/Application Support/EverythingMac/index.idx"
: > "$CACHE" 2>/dev/null || true   # truncate (not rm) → load fails → full rescan

launchctl kickstart -k "gui/$(id -u)/com.everythingmac.indexer" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/com.everythingmac.search" 2>/dev/null || true

open "/Applications/EverythingMac.app"
echo "Launched /Applications/EverythingMac.app"
echo "The indexing agent is rebuilding in the background."
