#!/usr/bin/env bash
#
# install.sh — build Release and install Notable to /Applications.
#
#   scripts/install.sh
#
# TCC permissions (Microphone, Calendars, System Audio Recording, Accessibility,
# Input Monitoring) are keyed to the app at /Applications/Notable.app, so we
# always install there. The Release build goes to an unsynced derivedDataPath
# under $TMPDIR — when the repo lives in a synced folder, the file provider breaks
# codesign mid-build (see CLAUDE.md).
#
# A local `cp -R` install carries no quarantine flag, but we strip it anyway so
# this script also works to install a zip that was downloaded from a Release.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> xcodegen generate"
xcodegen generate

DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/notable-install-XXXXXX")"
trap 'rm -rf "$DERIVED"' EXIT

# Quit a running Notable before replacing its bundle.
#
# `rm -rf /Applications/Notable.app` under a running app deletes the bundle out
# from under it: the process keeps going on the inode it already has, its TCC
# grants and its menu-bar item stay, and the next `open` starts a *second*
# instance next to the first. Ask it to quit, wait, and only then replace it.
quit_notable() {
  local dest="$1"
  [ -d "$dest" ] || return 0
  pgrep -x Notable >/dev/null 2>&1 || return 0
  echo "==> Quitting the running Notable"
  osascript -e 'tell application id "de.jonasgehring.notable" to quit' 2>/dev/null || true
  for _ in $(seq 1 30); do
    pgrep -x Notable >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  echo "Notable is still running — quit it and run this again." >&2
  exit 1
}

echo "==> Building Release to $DERIVED (outside any synced folder)"
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Release \
  -derivedDataPath "$DERIVED" build

APP="$DERIVED/Build/Products/Release/Notable.app"
[ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }

DEST="/Applications/Notable.app"
quit_notable "$DEST"
echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"

echo "==> Clearing quarantine on $DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo ""
echo "Installed Notable to $DEST"
echo "If this is the first cert-signed build, re-grant TCC permissions once (see docs/RELEASING.md)."
