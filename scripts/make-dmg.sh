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
#   NOTARY_PROFILE=<name>   notarytool keychain profile (default: notable-notary)
#   SKIP_BUILD=1            reuse the existing Release build
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$(ls -d build/Build/Products/Release/Notable.app 2>/dev/null)/Contents/Info.plist" 2>/dev/null || echo dev)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notable-notary}"
DERIVED="$REPO_ROOT/build"
APP="$DERIVED/Build/Products/Release/Notable.app"

# Pick the best identity available rather than failing on a missing one.
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  IDENTITY="Developer ID Application"
  HARDENED=YES
  SIGN_FLAGS="--timestamp"
  DISTRIBUTABLE=1
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
  IDENTITY="Apple Development"
  HARDENED=NO
  SIGN_FLAGS=""
  DISTRIBUTABLE=0
else
  echo "No usable signing identity in the keychain." >&2
  exit 1
fi
echo "==> Signing identity: $IDENTITY"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "==> Building Release"
  xcodegen generate >/dev/null
  xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" ENABLE_HARDENED_RUNTIME="$HARDENED" \
    build | tail -3
fi
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

# ----- staging: the app + the classic drop target -------------------------
STAGE="$(mktemp -d)/Notable"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DERIVED/Notable-$VERSION.dmg"
rm -f "$DMG"
echo "==> Creating $DMG"
hdiutil create -volname "Notable $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

# ----- notarize, if it can succeed at all ---------------------------------
if [ "$DISTRIBUTABLE" = "1" ]; then
  echo "==> Notarizing (this takes a few minutes)"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo
  echo "Fertig: $DMG"
  echo "Notarisiert und gestapelt — Empfänger können es direkt öffnen."
else
  echo
  echo "Fertig: $DMG"
  echo
  echo "ACHTUNG: signiert mit \"Apple Development\" — Gatekeeper lehnt das auf"
  echo "fremden Macs ab (spctl: rejected). Der Empfänger muss die App einmalig"
  echo "per Rechtsklick → Öffnen bestätigen, oder:"
  echo "    xattr -dr com.apple.quarantine /Applications/Notable.app"
  echo
  echo "Für ein wirklich verschickbares DMG braucht es ein \"Developer ID"
  echo "Application\"-Zertifikat (Apple Developer Program, 99 \$/Jahr) plus"
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE"
  echo "Danach erzeugt genau dieses Skript automatisch ein notarisiertes DMG."
fi
