#!/usr/bin/env bash
#
# notarize.sh — build a Release .app, notarize it, and staple the ticket.
#
#   scripts/notarize.sh                    # build Release, notarize, staple
#   scripts/notarize.sh path/to/Notable.app  # notarize an app that already exists
#   scripts/notarize.sh --install          # ... and replace /Applications/Notable.app
#
# This is the everyday counterpart to release.sh: no version bump, no tag, no
# clean-tree requirement, nothing published. Use it when you want a Gatekeeper-
# clean .app to hand to another Mac without cutting a release. release.sh does
# the same notarization as part of the release ceremony; the two must not drift.
#
# Notarization is not a publication: Apple receives only the built .app, keeps
# the submission private to this Apple ID, and lists it nowhere. What becomes
# visible to anyone holding the binary is the signing identity name — that is
# inherent to Developer ID, not to notarizing.
#
# Needs, once:
#   xcrun notarytool store-credentials "<profile>" \
#     --apple-id <apple-id> --team-id <team-id>      # prompts for an app-specific pw
# The profile name is read from ~/.config/notarize/profile; $NOTARY_PROFILE wins.
#
set -euo pipefail

# NOTE: never `producer | grep -q` under `set -o pipefail`. `grep -q` exits the
# moment it matches, the producer then gets SIGPIPE on its next write, and the
# pipeline reports 141 — so the check fails *precisely when it succeeds*. That
# cost one release: a correctly Developer-ID-signed app was rejected as unsigned.
# Capture first, match against the variable with a herestring.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ----- args ---------------------------------------------------------------
APP_ARG=""
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *)  APP_ARG="$arg" ;;
  esac
done

# The profile NAME lives in ONE place, so renaming it is a one-line change:
# $NOTARY_PROFILE, else ~/.config/notarize/profile, else the fallback below.
# notarytool has neither a rename nor a delete, and it keeps the credentials in
# the data-protection keychain, which `security` cannot even enumerate — so a
# "rename" is always: store-credentials under the new name, then point this file
# at it. The old profile stays behind, unreachable and harmless.
PROFILE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/notarize/profile"
if [ -z "${NOTARY_PROFILE:-}" ] && [ -r "$PROFILE_FILE" ]; then
  NOTARY_PROFILE="$(tr -d '[:space:]' < "$PROFILE_FILE")"
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-app-notary}"

# ----- 0. credentials, before spending five minutes on a build ------------
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "No notarytool credentials for profile '$NOTARY_PROFILE'. Create them once with:" >&2
  echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id <your-team-id>" >&2
  exit 1
fi

# ----- 1. get an app ------------------------------------------------------
if [ -n "$APP_ARG" ]; then
  APP="$(cd "$(dirname "$APP_ARG")" && pwd)/$(basename "$APP_ARG")"
  [ -d "$APP" ] || { echo "Not an app bundle: $APP" >&2; exit 1; }
  echo "==> Using existing app at $APP"
else
  echo "==> xcodegen generate"
  xcodegen generate

  # Build to an unsynced derivedDataPath: in a synced folder (iCloud, Dropbox) the
  # file provider decorates the product and codesign fails with "resource fork,
  # Finder information, or similar detritus not allowed" (see CLAUDE.md).
  DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/notable-notarize-XXXXXX")"
  trap 'rm -rf "$DERIVED"' EXIT
  echo "==> Building Release to $DERIVED (outside any synced folder)"
  xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Release \
    -derivedDataPath "$DERIVED" build

  APP="$DERIVED/Build/Products/Release/Notable.app"
  [ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }
fi

# ----- 2. the signature has to be Developer ID ----------------------------
# The notary service rejects anything else, and it rejects it *after* the upload
# and the queue wait — so check here, where the answer is instant.
echo "==> Verifying signature"
codesign --verify --deep --strict "$APP"
# Read the AUTHORITY line, not the designated requirement: the DR encodes the
# certificate kind as OIDs (field.1.2.840.113635.100.6.1.13) and never contains
# the string "Developer ID Application", so grepping it rejects valid apps.
INFO="$(codesign -d --verbose=2 "$APP" 2>&1 || true)"
# Display only — `|| true` because under `set -e` + pipefail a grep that finds
# nothing would abort the script before the real checks below ever run.
grep -E '^(Authority=Developer ID|TeamIdentifier=|Timestamp=)' <<<"$INFO" | sed 's/^/    /' || true
if ! grep -q '^Authority=Developer ID Application:' <<<"$INFO"; then
  echo "App is not Developer ID signed — notarization would be rejected." >&2
  echo "Set CODE_SIGN_IDENTITY: \"Developer ID Application\" + ENABLE_HARDENED_RUNTIME: YES in project.yml." >&2
  exit 1
fi
# Hardened runtime and a secure timestamp are the other two hard requirements;
# Apple checks them only after the upload and the queue wait.
grep -q 'flags=.*runtime' <<<"$INFO" || { echo "Hardened runtime is off — notarization would be rejected." >&2; exit 1; }
grep -q '^Timestamp=' <<<"$INFO" || { echo "Signature has no secure timestamp — notarization would be rejected." >&2; exit 1; }

# ----- 3. submit ----------------------------------------------------------
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
DIST="$REPO_ROOT/build"
mkdir -p "$DIST"
ZIP="$DIST/Notable-$VERSION-$BUILD.zip"

echo "==> Zipping $VERSION ($BUILD) to $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Notarizing (profile: $NOTARY_PROFILE) — waits for Apple, can take a few minutes"
# On rejection, --wait exits non-zero and the log holds the reason; fetch it
# rather than leaving the user with a bare "Invalid".
if ! SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; then
  echo "$SUBMIT_OUT"
  ID="$(echo "$SUBMIT_OUT" | awk '/id: /{print $2; exit}')"
  if [ -n "$ID" ]; then
    echo "==> Notarization failed — fetching the log for $ID"
    xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" || true
  fi
  exit 1
fi
echo "$SUBMIT_OUT"

# ----- 4. staple ----------------------------------------------------------
# Stapling writes the ticket into the bundle so it opens offline; without it
# Gatekeeper has to reach Apple on first launch.
echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP" || true

echo "==> Re-zipping the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ----- 5. optional install ------------------------------------------------
if [ "$INSTALL" -eq 1 ]; then
  DEST="/Applications/Notable.app"
  echo "==> Installing to $DEST"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
fi

echo ""
echo "Notarized and stapled Notable $VERSION ($BUILD)"
echo "  asset: $ZIP"
echo "Nothing was committed, tagged, or published."
