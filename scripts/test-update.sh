#!/usr/bin/env bash
#
# test-update.sh — run ONE real unattended update, end to end (Spec 25 §3.9).
#
#   scripts/test-update.sh
#
# The build machine installs every release with scripts/install.sh before the
# updater could ever see it, so without this there is no proof the unattended
# path works on real hardware. What it does:
#
#   1. builds the current app (Debug — only Debug builds honour `updateFeedURL`)
#      and the same app as version 9.9.9-test, both with the project's signing
#      identity, so the updater's team check and the TCC grants both hold;
#   2. zips the 9.9.9-test build and serves it, plus a hand-made
#      `releases/latest` JSON, on 127.0.0.1 with `python3 -m http.server`;
#   3. REPLACES /Applications/Notable.app with the base build (asks first),
#      points it at the local feed and launches it;
#   4. waits for the app to swap itself to 9.9.9-test and checks what can be
#      checked from a shell: the version, that it relaunched, that the
#      designated requirement did not change (TCC grants hang on it), and that
#      the new version recorded the update as unattended.
#
# Close every Notable window before step 3, or it waits ten minutes for you to
# stop typing (that is the feature). Afterwards, return to the real build:
#
#   scripts/install.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PORT="${PORT:-8765}"
TEST_VERSION="9.9.9-test"
DEST="/Applications/Notable.app"
BUNDLE_ID="de.jonasgehring.notable"

cat <<EOF
This replaces $DEST with a Debug build of the current source and lets it
update itself to $TEST_VERSION from a server on 127.0.0.1:$PORT.
Afterwards run scripts/install.sh to return to the release build.
EOF
read -r -p "Continue? [y/N] " answer
[[ "$answer" == [yY]* ]] || { echo "Aborted."; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/notable-update-test-XXXXXX")"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  defaults delete "$BUNDLE_ID" updateFeedURL 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Same as scripts/install.sh: never replace a bundle under a running app.
quit_notable() {
  pgrep -x Notable >/dev/null 2>&1 || return 0
  echo "==> Quitting the running Notable"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  for _ in $(seq 1 30); do
    pgrep -x Notable >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  echo "Notable is still running — quit it and run this again." >&2
  exit 1
}

version_of() {
  /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || true
}

echo "==> xcodegen generate"
xcodegen generate >/dev/null

echo "==> Building the base (Debug, current version)"
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Debug \
  -derivedDataPath "$WORK/base" build >/dev/null
echo "==> Building the update ($TEST_VERSION)"
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Debug \
  -derivedDataPath "$WORK/next" MARKETING_VERSION="$TEST_VERSION" build >/dev/null
BASE="$WORK/base/Build/Products/Debug/Notable.app"
NEXT="$WORK/next/Build/Products/Debug/Notable.app"
[ "$(version_of "$NEXT")" = "$TEST_VERSION" ] || { echo "The update build is not $TEST_VERSION." >&2; exit 1; }

echo "==> Serving the feed on 127.0.0.1:$PORT"
mkdir -p "$WORK/feed"
ZIP_NAME="Notable-$TEST_VERSION.zip"
ditto -c -k --keepParent "$NEXT" "$WORK/feed/$ZIP_NAME"
cat > "$WORK/feed/latest.json" <<JSON
{
  "tag_name": "v$TEST_VERSION",
  "name": "Notable $TEST_VERSION",
  "body": "- Testlauf des automatischen Updates (scripts/test-update.sh)",
  "html_url": "http://127.0.0.1:$PORT/",
  "assets": [
    { "name": "$ZIP_NAME", "browser_download_url": "http://127.0.0.1:$PORT/$ZIP_NAME" }
  ]
}
JSON
( cd "$WORK/feed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
sleep 1
curl -fsS "http://127.0.0.1:$PORT/latest.json" >/dev/null || { echo "The feed server did not start." >&2; exit 1; }

echo "==> Installing the base build to $DEST"
quit_notable
rm -rf "$DEST"
ditto "$BASE" "$DEST"
DR_BEFORE="$(codesign -d -r- "$DEST" 2>&1 | grep '^designated' || true)"
FROM="$(version_of "$DEST")"

# A fresh start for the updater: no 24-hour throttle, nothing remembered.
defaults write "$BUNDLE_ID" updateFeedURL "http://127.0.0.1:$PORT/latest.json"
for key in updateLastCheckAt updatePendingVersion updateSkippedVersion updateLastVersion; do
  defaults delete "$BUNDLE_ID" "$key" 2>/dev/null || true
done

echo "==> Launching $FROM and waiting for the swap (up to 5 minutes)"
open "$DEST"
SWAPPED=0
for _ in $(seq 1 150); do
  if [ "$(version_of "$DEST")" = "$TEST_VERSION" ]; then SWAPPED=1; break; fi
  sleep 2
done
if [ "$SWAPPED" -ne 1 ]; then
  echo "FAIL: still $(version_of "$DEST") after 5 minutes." >&2
  echo "      Is a Notable window open? Console.app, subsystem de.jonasgehring.notable, says why it waits." >&2
  echo "      A download refused outright would point at App Transport Security for http://127.0.0.1." >&2
  exit 1
fi

echo "==> Swapped. Waiting for the relaunch"
RUNNING=0
for _ in $(seq 1 30); do
  if pgrep -x Notable >/dev/null 2>&1; then RUNNING=1; break; fi
  sleep 1
done
sleep 3 # the new version records the outcome a moment after launch
DR_AFTER="$(codesign -d -r- "$DEST" 2>&1 | grep '^designated' || true)"
LAST="$(defaults read "$BUNDLE_ID" updateLastVersion 2>/dev/null || true)"
UNATTENDED="$(defaults read "$BUNDLE_ID" updateLastUnattended 2>/dev/null || true)"

status=0
check() { if [ "$2" = "1" ]; then echo "  ok    $1"; else echo "  FAIL  $1"; status=1; fi; }
echo ""
echo "Result ($FROM → $TEST_VERSION):"
check "version is $TEST_VERSION"                         "$SWAPPED"
check "the app relaunched"                               "$RUNNING"
check "designated requirement unchanged (TCC grants hold)" "$([ -n "$DR_BEFORE" ] && [ "$DR_BEFORE" = "$DR_AFTER" ] && echo 1)"
check "recorded as the last update"                      "$([ "$LAST" = "$TEST_VERSION" ] && echo 1)"
check "recorded as unattended"                           "$([ "$UNATTENDED" = "1" ] && echo 1)"
cat <<EOF

Check by hand, because a shell cannot see it:
  - the notification "Notable wurde aktualisiert" appeared;
  - Settings → Allgemein shows "Zuletzt aktualisiert: $TEST_VERSION … — automatisch";
  - Settings → Berechtigungen: microphone and accessibility still granted,
    and the dictation hotkey still works.

Then return to the release build:  scripts/install.sh
EOF
exit $status
