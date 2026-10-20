#!/usr/bin/env bash
#
# check-entitlements.sh — fail if a built Notable.app lacks an entitlement
# that Signing/Notable.entitlements asks for.
#
#   scripts/check-entitlements.sh path/to/Notable.app
#
# Under the hardened runtime a missing entitlement is not an error anywhere:
# tccd denies the microphone without a prompt and AVAudioEngine records pure
# digital silence. That is how meetings went silent on the mic track for two
# weeks in 2026-08 while the app reported success. install.sh, release.sh and
# notarize.sh run this after the build, so such a bundle never gets installed.
#
# The keys are read from the entitlements file itself, so a new entitlement is
# checked without touching this script.
set -euo pipefail

APP="${1:?usage: check-entitlements.sh path/to/Notable.app}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$REPO_ROOT/Signing/Notable.entitlements"

# `--xml` prints the plist on stdout; older codesign only knows `:-`.
SIGNED="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
[ -n "$SIGNED" ] || SIGNED="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"

missing=0
for key in $(sed -n 's:.*<key>\(.*\)</key>.*:\1:p' "$SOURCE"); do
  if ! grep -qF "<key>$key</key>" <<<"$SIGNED"; then
    echo "Missing entitlement in $APP: $key" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "The bundle would run, but tccd would silently deny what these keys gate." >&2
  echo "Check CODE_SIGN_ENTITLEMENTS in project.yml." >&2
  exit 1
fi
echo "    entitlements: all keys from Signing/Notable.entitlements present"
