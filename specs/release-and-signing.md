# Spec: Stable signing, GitHub-Releases versioning, and auto-update

Status: proposal (spec only — no code or `project.yml` changes made by this document)
Scope: single user, macOS 14.4+, locally built, installed to `/Applications/Notable.app`
Repo: `github.com/jonas-gehring/notable` · Bundle ID: `de.jonasgehring.notable`

---

## 0. Problem statement (grounded)

Today `CODE_SIGN_IDENTITY = "-"` (ad-hoc) in `project.yml` for both targets. Verified on the
currently installed build:

```
$ codesign -dvvv /Applications/Notable.app
CodeDirectory ... flags=0x2(adhoc)
Signature=adhoc
TeamIdentifier=not set

$ codesign -d -r- /Applications/Notable.app
# designated => cdhash H"1a6a7c9df7a530a93331303973d00279c69a98b6" or cdhash H"2585d9..."
```

The **designated requirement (DR) is a list of `cdhash` values** — the raw code hash of *this*
build. TCC (the privacy DB) keys every grant to the app's bundle ID **plus its DR**. Because a new
build produces a new `cdhash`, the DR changes, TCC no longer recognizes the app, and macOS re-prompts
for **every** permission Notable uses: Microphone, Calendars, System Audio Recording, Accessibility
(paste / synthesized ⌘V), and Input Monitoring (the CGEventTaps in `HotkeyMonitor`). That is the top
pain point.

**Fix:** sign with a *stable identity* (a certificate). When code is signed by a real certificate,
`codesign` generates a DR of the form
`identifier "de.jonasgehring.notable" and certificate leaf = H"<hash of the signing cert>"`
— it pins the **certificate**, not the code hash. Re-signing every rebuild with the *same* cert
yields a **byte-identical DR**, so TCC keeps recognizing the app and all grants persist across
rebuilds and version bumps.

Two ways to get a stable cert:
- **A. Self-signed local cert** — free, offline, sufficient for a single machine. Recommended default.
- **B. Apple *Developer ID Application* cert** — requires a paid Apple Developer Program membership
  ($99/yr); enables **notarization**, which additionally solves the Gatekeeper-on-download problem
  (see §1.5). Strictly better *if* the app will be downloaded via a browser or run on other Macs.

Note: an `Apple Development` identity in the login keychain is **not** the right tool here. That is a
*development* cert — it expires roughly yearly, is not for distribution, and cannot be notarized. What
matters is whether the Apple ID's team is a *paid* Developer Program membership: if yes, a **Developer
ID Application** cert (option B) can be minted from the Apple Developer portal; if it is only a free
personal team, that option is unavailable and option A is the path.

---

## 1. Stable signing for TCC persistence

### 1.1 Option A — self-signed code-signing certificate (recommended default)

#### 1.1a Interactive path (Keychain Access — do this once)

1. Open **Keychain Access** → menu **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…**
2. Name: **`Notable Local Signing`**
3. Identity Type: **Self Signed Root**
4. Certificate Type: **Code Signing**
5. Check **Let me override defaults**, click Continue, and set **Validity period = 3650** days
   (the default is 365 — a short validity means signing starts failing in a year). Accept the rest.
6. Create. Leave it in the **login** keychain.
7. **Trust it for code signing:** in Keychain Access, double-click the new cert ▸ expand **Trust** ▸
   set **Code Signing = Always Trust** ▸ close (admin password prompt). This makes the generated DR
   verify as a valid identity rather than an untrusted-anchor error.

#### 1.1b Scriptable path (openssl + `security`) — reproducible, checked into `scripts/`

`scripts/make-signing-cert.sh` (idempotent; skips if the identity already exists):

```sh
#!/usr/bin/env bash
set -euo pipefail
CERT_NAME="Notable Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "Identity '$CERT_NAME' already present — nothing to do."; exit 0
fi

# 10-year self-signed leaf with the code-signing EKU codesign requires.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$CERT_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CERT_NAME" -out "$WORK/signing.p12" -passout pass:

# Import key+cert; pre-authorize codesign/security to use the private key.
security import "$WORK/signing.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust the cert for code signing (prompts for admin password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# Allow codesign to use the key non-interactively (avoids the per-build
# "codesign wants to sign using key ..." popup). Prompts for the login password.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$(read -rsp 'login keychain password: ' p; echo "$p")" "$KEYCHAIN" >/dev/null

echo "Created and trusted '$CERT_NAME'."
security find-identity -v -p codesigning | grep "$CERT_NAME"
```

**One-time interactive steps** (either path):
- Run the script (or complete the Certificate Assistant flow) — **once**.
- Approve the **admin-password** prompt from `add-trusted-cert` (trust the root for code signing).
- Approve the **login-keychain-password** prompt from `set-key-partition-list`. If you skip that step,
  the *first* `codesign` of each session shows a **"codesign wants to sign using key … in your
  keychain"** dialog — click **Always Allow** and it never asks again.

**Back up the identity.** Export `Notable Local Signing` (with private key) as a `.p12` from Keychain
Access and store it safely. If the key is lost, the DR can never be reproduced and TCC grants reset
for good.

#### 1.1c Wire into `project.yml`

Change the `Notable` app target's `settings.base`:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.jonasgehring.notable
        CODE_SIGN_IDENTITY: "Notable Local Signing"   # was "-"
        CODE_SIGN_STYLE: Manual
        ENABLE_HARDENED_RUNTIME: NO                    # keep NO for self-signed (see 1.5)
        ENABLE_APP_SANDBOX: NO
        COMBINE_HIDPI_IMAGES: YES
        OTHER_CODE_SIGN_FLAGS: "--timestamp=none"      # no TSA needed for local self-signed
```

Leave the **`NotableTests`** target at `CODE_SIGN_IDENTITY: "-"` — the xctest bundle needs no stable
DR and ad-hoc keeps the test run dependency-free.

Then `xcodegen generate` and rebuild. `codesign` runs automatically as the last build phase; no manual
`codesign` invocation is required for local Debug/Release builds.

### 1.2 Option B — Developer ID Application (only if the Apple team is a paid membership)

If the Apple team is a paid Developer Program membership:

1. Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ **+ ▸ Developer ID Application** (or create in
   the developer portal and download). This produces a `Developer ID Application: …` identity.
2. `project.yml`: `CODE_SIGN_IDENTITY: "Developer ID Application"` and
   **`ENABLE_HARDENED_RUNTIME: YES`** (notarization requires the hardened runtime).
   - Hardened runtime + the app's use of the microphone/Apple events is already covered by the
     usage-description Info.plist keys; the CGEventTap / Accessibility paths are gated by TCC at
     runtime, not by entitlements, so **no extra entitlements file is needed** for a non-sandboxed app.
     (If hardened runtime ever rejects a capability, add a `Notable.entitlements` with the specific
     `com.apple.security.cs.*` key and reference it via `CODE_SIGN_ENTITLEMENTS`.)
3. The DR becomes `… and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"` — stable
   across cert renewals (pinned to Team ID, not the individual cert), which is *even more* durable than
   the self-signed leaf-hash pin.

### 1.3 Why the DR change is what breaks TCC (one-paragraph rationale to keep on record)

TCC stores each grant as `(client bundle id, requirement)`. The requirement is the app's DR. Ad-hoc
signing has no certificate, so `codesign` falls back to a `cdhash`-based DR — which is the hash of the
Mach-O, and changes on every compile. Certificate signing produces a certificate-based DR, which is
invariant as long as the same cert signs. Nothing else about the app (bundle id, path, Info.plist)
needs to change; pinning the identity is the whole fix.

### 1.4 Verification

After building + installing the first cert-signed build:

```sh
# 1. Signature is now certificate-based, not adhoc:
codesign -dvvv /Applications/Notable.app 2>&1 | grep -E 'Authority|Signature|adhoc'
#   expect: Authority=Notable Local Signing   (and NO "Signature=adhoc")

# 2. The stable DR — this is the string TCC keys on:
codesign -d -r- /Applications/Notable.app
#   expect: identifier "de.jonasgehring.notable" and certificate leaf = H"...."
#   (NOT "cdhash H\"...\"")

# 3. Prove stability: rebuild, reinstall, diff the DR — must be identical:
codesign -d -r- /Applications/Notable.app > /tmp/dr1.txt
#   ...rebuild+reinstall...
codesign -d -r- /Applications/Notable.app > /tmp/dr2.txt
diff /tmp/dr1.txt /tmp/dr2.txt && echo "DR stable ✅"
```

TCC-side check (destructive — only for the initial proof, then re-grant once):
```sh
tccutil reset All de.jonasgehring.notable   # clears every Notable grant
```
Then: launch, grant all five permissions once, rebuild+reinstall, relaunch — **no** re-prompt should
appear. That is the acceptance test for the whole signing change.

### 1.5 Gatekeeper / quarantine caveat (matters specifically for GitHub Releases)

Local `cp -R` installs carry no quarantine flag, so a self-signed app launches with no warning. **But a
zip downloaded through a browser from a GitHub Release gets `com.apple.quarantine`**, and Gatekeeper
blocks non-notarized apps on first launch ("Notable can't be opened because Apple cannot check it").
Consequences:
- **Self-signed (Option A):** after downloading, clear quarantine before launch —
  `xattr -dr com.apple.quarantine /Applications/Notable.app` — or right-click ▸ Open once. The
  install/update script (§3) does this automatically, so for a single user this is a non-issue.
- **Developer ID + notarization (Option B):** the downloaded, notarized, stapled app launches with no
  warning. This is the concrete reason Option B is "strictly better" for download-based distribution.

---

## 2. Versioning

### 2.1 `project.yml`

Add to the `Notable` app target's `settings.base`:

```yaml
        MARKETING_VERSION: "1.0.0"        # CFBundleShortVersionString (semver, user-facing)
        CURRENT_PROJECT_VERSION: "1"      # CFBundleVersion (monotonic build counter)
```

And bind them in the app target's `info.properties` (currently these are hardcoded to `1.0`/`1` in the
generated Info.plist):

```yaml
    info:
      path: Generated/Info.plist
      properties:
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        # ... existing keys unchanged ...
```

The release script is the single writer of these two values (§3), so the repo's `project.yml` always
reflects the last released version.

### 2.2 Version-bump + build + zip + release flow

`scripts/release.sh <new-marketing-version>` — e.g. `scripts/release.sh 1.1.0`:

```sh
#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?usage: release.sh <marketing-version, e.g. 1.1.0>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 0. Clean tree required (releases must be reproducible from a tagged commit).
[ -z "$(git status --porcelain)" ] || { echo "Working tree dirty — commit first."; exit 1; }

# 1. Bump versions in project.yml (MARKETING_VERSION = arg, CURRENT_PROJECT_VERSION = git count).
BUILD_NUM="$(git rev-list --count HEAD)"
/usr/bin/sed -i '' -E \
  -e "s/(MARKETING_VERSION:) .*/\1 \"$VERSION\"/" \
  -e "s/(CURRENT_PROJECT_VERSION:) .*/\1 \"$BUILD_NUM\"/" project.yml

# 2. Regenerate + Release build.
xcodegen generate
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Release \
  -derivedDataPath build build

APP="build/Build/Products/Release/Notable.app"

# 3. Verify the signature is the stable cert (fail fast if someone reverted to ad-hoc).
codesign -dvvv "$APP" 2>&1 | grep -q "Authority=Notable Local Signing" \
  || { echo "App is not signed with the stable identity — aborting."; exit 1; }
codesign --verify --deep --strict "$APP"

# 4. (Option B only) notarize + staple:
#   ditto -c -k --keepParent "$APP" "build/Notable-notarize.zip"
#   xcrun notarytool submit build/Notable-notarize.zip --keychain-profile notable-notary --wait
#   xcrun stapler staple "$APP"

# 5. Zip the app for release (ditto preserves the bundle + signature).
ZIP="build/Notable-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# 6. Commit the version bump, tag, push.
git add project.yml
git commit -m "Release v$VERSION"
git tag "v$VERSION"
git push origin HEAD --tags

# 7. Publish the GitHub Release with the zip asset.
gh release create "v$VERSION" "$ZIP" \
  --title "Notable v$VERSION" \
  --generate-notes
#   ^ add: sign_update output + appcast.xml as a second asset if Sparkle is adopted (§3).

echo "Released v$VERSION → $ZIP"
```

Notes:
- `gh` is present and authenticated.
- `CURRENT_PROJECT_VERSION` is derived from `git rev-list --count HEAD` so it's monotonic and never
  hand-managed; `MARKETING_VERSION` is the only human-chosen value.

---

## 3. Auto-update

### 3.1 Option S — Sparkle (SPM) with a GitHub-Releases appcast

Sparkle 2.x is the standard macOS updater and supports SPM.

Integration sketch:
- **Package:** add to `project.yml`
  ```yaml
  packages:
    Sparkle:
      url: https://github.com/sparkle-project/Sparkle
      from: 2.6.0
  ```
  and `- package: Sparkle` under the `Notable` target dependencies.
- **Keys:** generate an EdDSA key pair once with Sparkle's `generate_keys` tool; it stores the private
  key in the keychain and prints the **public** key. Add to Info.plist:
  ```yaml
  SUFeedURL: "https://raw.githubusercontent.com/jonas-gehring/notable/main/appcast.xml"
  SUPublicEDKey: "<base64 public key from generate_keys>"
  SUEnableAutomaticChecks: true
  ```
- **Wire-up:** hold an `SPUStandardUpdaterController` in `AppContainer`; add a **"Check for Updates…"**
  menu item bound to `checkForUpdates(_:)`. (`LSUIElement` menu-bar app — attach to the existing
  status-bar menu.)
- **Per release:** the script runs Sparkle's `sign_update Notable-<v>.zip` → EdDSA signature; write/append
  an `<item>` to `appcast.xml` with the enclosure `url` = the GitHub Release asset URL, `sparkle:version`
  = `CURRENT_PROJECT_VERSION`, `sparkle:shortVersionString` = `MARKETING_VERSION`, and
  `sparkle:edSignature` = the signature; commit `appcast.xml` (that's what `SUFeedURL` points at).
- **Signing interaction:** Sparkle verifies (a) the EdDSA signature and (b) that the update's code
  signature matches the running app's. With the stable self-signed cert both hold across versions, so
  self-signed + Sparkle works; downloaded-update quarantine is handled by Sparkle itself.

Cost: one framework, an EdDSA key to guard, and an `appcast.xml` to maintain — real one-click updates.

### 3.2 Option L — lightweight "check GitHub latest release and prompt" (recommended)

No framework. A small `UpdateChecker` (~40 lines) plus a menu item:

1. `GET https://api.github.com/repos/jonas-gehring/notable/releases/latest` (unauthenticated is fine for
   a public repo, 60 req/h/IP; for a **private** repo send `Authorization: Bearer <token>`).
2. Compare `tag_name` (strip leading `v`) against `Bundle.main` `CFBundleShortVersionString` using a
   semver compare.
3. If newer: show an `NSAlert` from the menu-bar app — "Notable 1.1.0 is available" — with buttons
   **Download**, **Release Notes**, **Later**. **Download** either opens the release page in the browser,
   or (nicer) downloads the asset zip to `~/Downloads`, `xattr -dr com.apple.quarantine` it, and reveals
   it in Finder for a drag-to-Applications.
4. Optionally auto-check once per launch / once per day (`UserDefaults` timestamp), plus manual
   "Check for Updates…".

Fully in-place self-replacement (quit → swap `/Applications/Notable.app` → relaunch) is possible via a
detached helper shell script, but is more machinery than a single user needs; opening the download is
enough.

### 3.3 Recommendation

**Adopt Option L (lightweight GitHub-latest check).** Rationale, consistent with the project's
"personal tool, single user" ethos: no framework, no EdDSA key to guard, no `appcast.xml` to keep in
sync, no hosting question. There is one user, installing to `/Applications` directly; a prompt
that surfaces "a newer tag exists" and hands off the download covers the actual need. Reach for Sparkle
(Option S) only if silent, unattended one-click updates later become worth the maintenance — the two
are not mutually exclusive (Option L can be replaced by Sparkle without touching the signing/versioning
work below it).

---

## 4. Exact files to add / change

**Change `project.yml`** (app target only):
- `CODE_SIGN_IDENTITY: "-"` → `"Notable Local Signing"` (or `"Developer ID Application"` for Option B).
- add `OTHER_CODE_SIGN_FLAGS: "--timestamp=none"` (Option A) or set `ENABLE_HARDENED_RUNTIME: YES` (Option B).
- add `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` to `settings.base`.
- add `CFBundleShortVersionString`/`CFBundleVersion` = the `$(…)` refs to `info.properties`.
- (Sparkle only) add the `Sparkle` package + dependency and `SUFeedURL`/`SUPublicEDKey`/`SUEnableAutomaticChecks`.
- Leave `NotableTests` at `CODE_SIGN_IDENTITY: "-"`.

**Add files:**
- `scripts/make-signing-cert.sh` — §1.1b (run once).
- `scripts/release.sh` — §2.2 (version bump → build → verify → zip → tag → `gh release create`).
- (Sparkle only) `appcast.xml` at repo root; `scripts/sign-update.sh` wrapper around Sparkle `sign_update`.
- (Option L) `Sources/Notable/Update/UpdateChecker.swift` + a menu item — production code, out of scope
  for this spec; listed so the wiring is known.

**Info.plist:** all version + Sparkle keys flow from `project.yml` `info.properties`; do **not**
hand-edit `Generated/Info.plist` (it is regenerated by `xcodegen` and gitignored).

**Regenerate after any `project.yml` edit:** `xcodegen generate`.

---

## 5. Acceptance criteria

Signing / TCC:
- `codesign -dvvv /Applications/Notable.app` shows `Authority=Notable Local Signing` (or the Developer ID
  authority) and **no** `Signature=adhoc`.
- `codesign -d -r-` prints a **certificate-based** DR (`certificate leaf = H"…"` / `certificate
  leaf[subject.OU] = "<TEAMID>"`), not `cdhash H"…"`.
- The DR is **byte-identical** across two independent Release builds (`diff` of §1.4 step 3).
- After granting all five TCC permissions once, a rebuild + reinstall triggers **zero** re-prompts for
  Microphone, Calendars, System Audio Recording, Accessibility, and Input Monitoring.
- `codesign --verify --deep --strict` passes; the app launches from `/Applications`.

Versioning / release:
- `scripts/release.sh 1.1.0` produces a `v1.1.0` git tag, a GitHub Release with `Notable-1.1.0.zip`
  attached, and `About`/menu shows `1.1.0`.
- `CFBundleShortVersionString` in the shipped app equals the release tag (minus `v`).
- The script aborts if the tree is dirty or the app isn't signed with the stable identity.

Auto-update (Option L):
- The menu item detects a newer published release and offers Download / Release Notes / Later; on an
  up-to-date app it reports "You're up to date."
- (Option S, if adopted) an older installed build, pointed at the committed `appcast.xml`, offers and
  installs the update in one click with a valid EdDSA signature.

---

## 6. Open decisions

1. **Self-signed (A) vs Developer ID (B).** Is the Apple team a *paid* Developer Program
   membership? If yes and you want browser-downloadable, warning-free installs (or ever running Notable
   on a second Mac), choose **B** (notarized). If it's a free personal team, or the app is only ever
   installed by you via the local build script, **A** (self-signed, free) is enough. *Default
   recommendation: A now; revisit if you distribute beyond your own machine.*
2. **Sparkle (S) vs lightweight (L).** *Recommendation: L* for a single-user tool. Choose S only if you
   want unattended one-click updates and accept the EdDSA-key + appcast maintenance.
3. **Public vs private GitHub repo for releases.** Public → unauthenticated update checks "just work"
   and downloads need no token. Private → the update checker and any download must send a GitHub token
   (Keychain-stored), and asset URLs are short-lived signed URLs. Which visibility should `notable` have?
4. **Notarization credentials (only if B).** Store an `notarytool` keychain profile
   (`xcrun notarytool store-credentials`) with an app-specific password or API key — confirm which.
