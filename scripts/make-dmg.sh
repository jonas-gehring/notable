#!/bin/bash
# Builds Notable (Release) and packages it as a drag-to-Applications DMG.
#
# Two very different outcomes, depending on what is in the keychain:
#
#   A) "Developer ID Application" cert + stored notarytool credentials
#      → the DMG is notarized and stapled: the recipient double-clicks and it
#        just opens. This is the only "einfach verschicken" path.
#
#   B) Only an "Apple Development" cert (the current state of this Mac)
#      → the app is signed but Gatekeeper REJECTS it on any other Mac
#        (`spctl -a` says "rejected"). The recipient must right-click → Öffnen
#        and confirm once, or run:
#            xattr -dr com.apple.quarantine /Applications/Notable.app
#        The script prints this warning at the end instead of pretending.
#
# Usage: scripts/make-dmg.sh [version]
#   NOTARY_PROFILE=<name>   notarytool keychain profile
#                           (default: ~/.config/notarize/profile)
#   SKIP_BUILD=1            reuse the existing Release build
#   SKIP_NOTARIZE=1         build and package, but do not notarize (case B output)
set -euo pipefail

# NOTE: never `producer | grep -q` under `set -o pipefail`. `grep -q` exits the
# moment it matches, the producer then gets SIGPIPE on its next write, and the
# pipeline reports 141 — so the check fails *precisely when it succeeds*. That
# cost one release: a correctly Developer-ID-signed app was rejected as unsigned.
# Capture first, match against the variable with a herestring.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The version is read from the BUILT app further down, not here: PlistBuddy
# prints "File Doesn't Exist, Will Create: ..." to STDOUT when the plist is
# missing, so a pre-build read does not fail — it silently returns that sentence
# as the version and it ends up in the DMG's file name.
VERSION="${1:-}"
# The profile NAME lives in ONE place, so renaming it is a one-line change:
# $NOTARY_PROFILE, else ~/.config/notarize/profile, else the fallback below.
PROFILE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/notarize/profile"
if [ -z "${NOTARY_PROFILE:-}" ] && [ -r "$PROFILE_FILE" ]; then
  NOTARY_PROFILE="$(tr -d '[:space:]' < "$PROFILE_FILE")"
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-app-notary}"
# Build OUTSIDE the repo. In a synced folder (iCloud, Dropbox) the file provider
# decorates the build product with extended attributes and codesign then fails
# with "resource fork, Finder information, or similar detritus not allowed" — a
# failure that looks nothing like its cause. release.sh/install.sh/notarize.sh do
# the same. Unlike those, this path is STABLE rather than a mktemp -d, because
# SKIP_BUILD=1 has to find the previous build next time round.
DERIVED="${TMPDIR:-/tmp}/notable-dmg-dd"
APP="$DERIVED/Build/Products/Release/Notable.app"
# The DMG itself is a deliverable, so it lands next to the release zips in the
# repo's (gitignored) build/ — only the intermediates stay out of the repo.
DIST="$REPO_ROOT/build"
mkdir -p "$DIST"

# How the app gets signed is project.yml's business (CODE_SIGN_IDENTITY +
# ENABLE_HARDENED_RUNTIME) plus Signing/Local.xcconfig for DEVELOPMENT_TEAM.
# This script must NOT override CODE_SIGN_IDENTITY on the xcodebuild command
# line: a command-line override applies to every target in the build, including
# the SPM package targets, and those have no DEVELOPMENT_TEAM — the build then
# dies with "Signing for swift-transformers_Hub requires a development team".
# So: build first, then read the identity back off the product.
IDENTITIES="$(security find-identity -v -p codesigning 2>&1 || true)"
if ! grep -q "Developer ID Application" <<<"$IDENTITIES"; then
  echo "No \"Developer ID Application\" identity in the keychain — project.yml asks for" >&2
  echo "one, so the build will fail. Install the certificate or change project.yml." >&2
  exit 1
fi
# Assume the configured Developer ID until the built product says otherwise.
DISTRIBUTABLE=1

# Check the credentials BEFORE the build, not after the DMG is already built:
# a missing keychain profile would otherwise surface ten minutes in, at submit.
if [ "$DISTRIBUTABLE" = "1" ] && [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials for profile '$NOTARY_PROFILE'. Create them once with:" >&2
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id <your-team-id>" >&2
    echo "Or re-run with SKIP_NOTARIZE=1 for an un-notarized DMG." >&2
    exit 1
  fi
fi

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "==> Building Release"
  xcodegen generate >/dev/null
  xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Release \
    -derivedDataPath "$DERIVED" build | tail -3
fi
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

# What did the build actually produce? Read the Authority line — the designated
# requirement encodes the certificate kind as OIDs and never spells it out.
INFO="$(codesign -d --verbose=2 "$APP" 2>&1 || true)"
IDENTITY="$(echo "$INFO" | sed -n 's/^Authority=\(.*\)/\1/p' | head -1)"
echo "==> Signed as: ${IDENTITY:-(unsigned)}"
if ! grep -q '^Authority=Developer ID Application:' <<<"$INFO"; then
  DISTRIBUTABLE=0
fi

if [ -z "$VERSION" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
fi
# A version with whitespace or newlines in it means the read went wrong; it would
# otherwise become part of a file name and break hdiutil in a puzzling way.
case "$VERSION" in
  ""|*[[:space:]]*) echo "Could not read a usable version from $APP (got: '$VERSION')" >&2; exit 1 ;;
esac
echo "==> Version: $VERSION"

# ----- staging: the app + the classic drop target -------------------------
STAGE="$(mktemp -d)/Notable"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/Notable-$VERSION.dmg"
rm -f "$DMG"
echo "==> Creating $DMG"
hdiutil create -volname "Notable $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

# ----- notarize, if it can succeed at all ---------------------------------
if [ "$DISTRIBUTABLE" = "1" ] && [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  echo "==> Notarizing (this takes a few minutes)"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo
  echo "Fertig: $DMG"
  echo "Notarisiert und gestapelt — Empfänger können es direkt öffnen."
elif [ "$DISTRIBUTABLE" = "1" ]; then
  # Developer ID signed, but notarization was skipped on purpose. Gatekeeper
  # still blocks this on another Mac — a valid signature is not a ticket.
  echo
  echo "Fertig: $DMG"
  echo
  echo "ACHTUNG: SKIP_NOTARIZE=1 — signiert, aber NICHT notarisiert. Auf fremden"
  echo "Macs meldet Gatekeeper \"kann nicht auf Schadsoftware überprüft werden\"."
  echo "Ohne SKIP_NOTARIZE erzeugt genau dieses Skript ein notarisiertes DMG."
else
  echo
  echo "Fertig: $DMG"
  echo
  echo "ACHTUNG: nicht mit \"Developer ID Application\" signiert — Gatekeeper lehnt das auf"
  echo "fremden Macs ab (spctl: rejected). Der Empfänger muss die App einmalig"
  echo "per Rechtsklick → Öffnen bestätigen, oder:"
  echo "    xattr -dr com.apple.quarantine /Applications/Notable.app"
  echo
  echo "Für ein wirklich verschickbares DMG braucht es ein \"Developer ID"
  echo "Application\"-Zertifikat (Apple Developer Program, 99 \$/Jahr) plus"
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE"
  echo "Danach erzeugt genau dieses Skript automatisch ein notarisiertes DMG."
fi
