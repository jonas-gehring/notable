#!/usr/bin/env bash
#
# release.sh — cut a Notable release.
#
#   scripts/release.sh <marketing-version> [--publish]
#   e.g. scripts/release.sh 1.0.0
#
# What it does (always):
#   1. Requires a clean working tree (releases must be reproducible from a commit).
#   2. Bumps MARKETING_VERSION (= the arg) and CURRENT_PROJECT_VERSION
#      (= git commit count, monotonic) in project.yml.
#   3. Regenerates the Xcode project and builds Release to a NON-iCloud
#      derivedDataPath under $TMPDIR — when the repo lives in a synced folder
#      (iCloud Drive, Dropbox), the file provider breaks codesign mid-build.
#   4. Verifies the signature is CERTIFICATE-based (a stable designated
#      requirement), not ad-hoc — an ad-hoc DR shows "cdhash" and would reset
#      every TCC grant on this Mac.
#   5. Zips the .app, NOTARIZES it (xcrun notarytool --wait, keychain profile
#      "notable-notary" or $NOTARY_PROFILE), STAPLES the ticket, and re-zips —
#      so the download opens on any Mac with no Gatekeeper warning. Needs a
#      "Developer ID Application" signature (project.yml) + stored credentials.
#      Set SKIP_NOTARIZE=1 to produce an un-notarized zip instead.
#
# Publishing (git commit/tag/push + `gh release create`) is GUARDED behind
# --publish and is OFF by default. Without --publish the script only PRINTS the
# commands to review and run by hand. Nothing is pushed or tagged
# unless you pass --publish explicitly.
#
set -euo pipefail

# ----- args ---------------------------------------------------------------
VERSION="${1:?usage: release.sh <marketing-version, e.g. 1.0.0> [--publish]}"
PUBLISH=0
for arg in "${@:2}"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be semver (X.Y.Z), got: $VERSION" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TAG="v$VERSION"

# ----- 0. clean tree ------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty — commit or stash first (releases build from a commit)." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG already exists — pick a new version." >&2
  exit 1
fi

# ----- 1. bump versions in project.yml ------------------------------------
BUILD_NUM="$(git rev-list --count HEAD)"
echo "==> Bumping to MARKETING_VERSION=$VERSION, CURRENT_PROJECT_VERSION=$BUILD_NUM"
/usr/bin/sed -i '' -E \
  -e "s/^([[:space:]]*MARKETING_VERSION:).*/\1 \"$VERSION\"/" \
  -e "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 \"$BUILD_NUM\"/" \
  project.yml

# ----- 2. regenerate + Release build to an unsynced DD --------------------
echo "==> xcodegen generate"
xcodegen generate

DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/notable-release-XXXXXX")"
trap 'rm -rf "$DERIVED"' EXIT
echo "==> Building Release to $DERIVED (outside any synced folder)"
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Release \
  -derivedDataPath "$DERIVED" build

APP="$DERIVED/Build/Products/Release/Notable.app"
[ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }

# ----- 3. verify the signature is certificate-based -----------------------
echo "==> Verifying certificate-based signature (stable designated requirement)"
codesign --verify --deep --strict "$APP"
DR="$(codesign -d -r- "$APP" 2>&1 || true)"
echo "    designated requirement: $DR"
if echo "$DR" | grep -q "cdhash"; then
  echo "App is ad-hoc signed (DR contains cdhash) — TCC grants would reset on every build." >&2
  echo "Set a stable CODE_SIGN_IDENTITY in project.yml and rebuild." >&2
  exit 1
fi

# ----- 4. zip, notarize, staple ------------------------------------------
# Notarization needs a "Developer ID Application" signature + hardened runtime,
# a secure timestamp, and stored notarytool credentials (a keychain profile).
# Set SKIP_NOTARIZE=1 to build an un-notarized zip (Gatekeeper-blocked on other
# Macs; fine on this machine with `xattr -dr com.apple.quarantine`).
DIST="$REPO_ROOT/build"
mkdir -p "$DIST"
ZIP="$DIST/Notable-$VERSION.zip"
echo "==> Zipping to $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> SKIP_NOTARIZE=1 — skipping notarization (zip is NOT notarized)"
else
  if ! echo "$DR" | grep -q "Developer ID Application"; then
    echo "App is not Developer ID signed — notarization would be rejected." >&2
    echo "Set CODE_SIGN_IDENTITY: \"Developer ID Application\" + ENABLE_HARDENED_RUNTIME: YES in project.yml," >&2
    echo "or re-run with SKIP_NOTARIZE=1 for an un-notarized build." >&2
    exit 1
  fi
  NOTARY_PROFILE="${NOTARY_PROFILE:-notable-notary}"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials for profile '$NOTARY_PROFILE'. Create them once with:" >&2
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id <your-team-id> --password <app-specific-pw>" >&2
    exit 1
  fi
  echo "==> Notarizing (profile: $NOTARY_PROFILE) — waits for Apple, can take a few minutes"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling the notarization ticket onto the app"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute -vv "$APP" || true
  echo "==> Re-zipping the stapled app"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo ""
echo "Built and signed Notable $VERSION"
echo "  asset: $ZIP"
echo ""

# ----- 5. publish (guarded) or print the commands -------------------------
if [ "$PUBLISH" -eq 1 ]; then
  echo "==> --publish: committing version bump, tagging, pushing, and creating the release"
  git add project.yml
  git commit -m "Release $TAG"
  git tag "$TAG"
  git push origin HEAD --tags
  gh release create "$TAG" "$ZIP" \
    --title "Notable $VERSION" \
    --generate-notes
  echo "Released $TAG."
else
  cat <<EOF
Publishing is OFF (no --publish). Nothing was committed, tagged, pushed, or released.
The project.yml version bump is on disk — review it, then run the following to publish:

  git add project.yml
  git commit -m "Release $TAG"
  git tag "$TAG"
  git push origin HEAD --tags
  gh release create "$TAG" "$ZIP" \\
    --title "Notable $VERSION" \\
    --generate-notes

(or re-run: scripts/release.sh $VERSION --publish)
EOF
fi
